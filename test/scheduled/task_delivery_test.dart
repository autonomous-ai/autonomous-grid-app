import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/hermes_tool.dart';
import 'package:grid_app/features/chat/logic/chat_sessions_controller.dart';
import 'package:grid_app/features/chat/logic/chat_store.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/playground/logic/chat_sender.dart';
import 'package:grid_app/features/playground/logic/playground_request.dart';
import 'package:grid_app/features/projects/logic/project_tasks_store.dart';
import 'package:grid_app/features/scheduled/logic/scheduled_jobs_controller.dart';
import 'package:grid_app/features/scheduled/logic/task_delivery.dart';
import 'package:grid_app/features/scheduled/logic/task_unread_store.dart';
import 'package:grid_app/infrastructure/cli/hermes_cron_service.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

/// A scheduler with a fixed job list and canned run outputs — no `hermes` binary,
/// no real `~/.hermes`.
class FakeCron implements HermesCronService {
  FakeCron({required this.jobsJson, this.outputs = const {}});

  final String jobsJson;
  final Map<String, List<CronOutput>> outputs;

  /// How many times each job's results were read.
  final reads = <String>[];

  @override
  Future<String?> readJobsJson() async => jobsJson;

  @override
  Future<List<CronOutput>> readOutputs(String jobId) async {
    reads.add(jobId);
    return outputs[jobId] ?? const [];
  }

  @override
  Future<void> create({
    required String schedule,
    required String prompt,
    required String name,
    String? workdir,
    String deliver = kDeliverLocal,
  }) async {}

  @override
  Future<void> pause(String id) async {}
  @override
  Future<void> resume(String id) async {}
  @override
  Future<void> remove(String id) async {}
  @override
  Future<void> runNow(String id) async {}
  @override
  Future<bool> schedulerRunning() async => true;
  @override
  Future<void> startScheduler() async {}
}

String _jobsJson() => '''
{"jobs": [
  {"id": "job-1", "name": "Daily digest", "prompt": "summarise",
   "schedule": {"expr": "0 8 * * *"}, "enabled": true}
]}
''';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_task_delivery_test');
  });
  tearDown(() => tmp.delete(recursive: true));

  ({ProviderContainer container, ChatStore chats, FakeCron cron}) harness(
    FakeCron cron,
  ) {
    final chats = ChatStore(directory: Directory('${tmp.path}/chats'));
    final container = ProviderContainer(
      overrides: [
        hermesCronServiceProvider.overrideWithValue(cron),
        // The agent is installed — otherwise there'd be no scheduler at all.
        hermesPathProvider.overrideWithValue('/bin/hermes'),
        chatStoreProvider.overrideWithValue(chats),
        chatSenderProvider.overrideWithValue(_NeverSender()),
        taskDeliveryStoreProvider.overrideWithValue(
          TaskDeliveryStore(file: File('${tmp.path}/task_delivery.json')),
        ),
        // The unread badge and the project links persist too — point them at the
        // temp dir so a sweep never reads or writes the real `~/.grid`.
        taskUnreadStoreProvider.overrideWithValue(
          TaskUnreadStore(file: File('${tmp.path}/task_unread.json')),
        ),
        projectTasksStoreProvider.overrideWithValue(
          ProjectTasksStore(file: File('${tmp.path}/project_tasks.json')),
        ),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, chats: chats, cron: cron);
  }

  test('a finished run lands in the task\'s own chat, stamped with when it '
      'ran', () async {
    final h = harness(
      FakeCron(
        jobsJson: _jobsJson(),
        outputs: {
          'job-1': [
            (at: DateTime(2026, 7, 14, 8), text: 'Three PRs need review.'),
          ],
        },
      ),
    );

    await h.container.read(taskDeliveryProvider.notifier).sweep();

    final chat = h.container
        .read(chatSessionsProvider)
        .conversations
        .singleWhere((c) => c.id == taskConversationId('job-1'));
    expect(chat.title, 'Daily digest');
    expect(chat.messages.single.role, ChatRole.assistant);
    expect(chat.messages.single.text, contains('Three PRs need review.'));
    expect(chat.messages.single.text, contains('14/07 at 08:00'));
    // On disk too, so closing the app doesn't lose the result.
    expect(h.chats.loadAll().single.messages, hasLength(1));
  });

  test('a result is delivered once — not again on the next sweep, or the next '
      'launch', () async {
    final h = harness(
      FakeCron(
        jobsJson: _jobsJson(),
        outputs: {
          'job-1': [(at: DateTime(2026, 7, 14, 8), text: 'Same answer')],
        },
      ),
    );

    await h.container.read(taskDeliveryProvider.notifier).sweep();
    await h.container.read(taskDeliveryProvider.notifier).sweep();

    expect(h.chats.loadAll().single.messages, hasLength(1));

    // A fresh app (new container, same stores) doesn't re-deliver it either.
    final next = harness(h.cron);
    await next.container.read(taskDeliveryProvider.notifier).sweep();
    expect(next.chats.loadAll().single.messages, hasLength(1));
  });

  test('the next morning\'s run is appended to the same chat', () async {
    final h = harness(
      FakeCron(
        jobsJson: _jobsJson(),
        outputs: {
          'job-1': [(at: DateTime(2026, 7, 14, 8), text: 'Monday')],
        },
      ),
    );
    await h.container.read(taskDeliveryProvider.notifier).sweep();

    final tomorrow = harness(
      FakeCron(
        jobsJson: _jobsJson(),
        outputs: {
          'job-1': [
            (at: DateTime(2026, 7, 14, 8), text: 'Monday'),
            (at: DateTime(2026, 7, 15, 8), text: 'Tuesday'),
          ],
        },
      ),
    );
    await tomorrow.container.read(taskDeliveryProvider.notifier).sweep();

    final chat = tomorrow.chats.loadAll().single;
    expect(chat.messages, hasLength(2));
    expect(chat.messages.last.text, contains('Tuesday'));
    expect(chat.updatedAt, DateTime(2026, 7, 15, 8));
  });

  test('a result never takes over the chat the user is reading', () async {
    final h = harness(
      FakeCron(
        jobsJson: _jobsJson(),
        outputs: {
          'job-1': [(at: DateTime(2026, 7, 14, 8), text: 'Digest')],
        },
      ),
    );
    // The user is in the middle of another conversation.
    h.chats.save(
      Conversation(
        id: 'mine',
        title: 'My chat',
        model: 'm',
        createdAt: DateTime(2026, 7, 13),
        updatedAt: DateTime(2026, 7, 13),
      ),
    );
    final container = h.container;
    container.read(chatSessionsProvider.notifier).select('mine');

    await container.read(taskDeliveryProvider.notifier).sweep();

    expect(container.read(chatSessionsProvider).activeId, 'mine');
    expect(container.read(chatSessionsProvider).conversations, hasLength(2));
  });

  test('nothing to deliver, nothing written', () async {
    final h = harness(FakeCron(jobsJson: _jobsJson()));

    await h.container.read(taskDeliveryProvider.notifier).sweep();

    expect(h.chats.loadAll(), isEmpty);
    expect(File('${tmp.path}/task_delivery.json').existsSync(), isFalse);
  });

  test('reads the runs Hermes actually wrote — oldest first, empty and '
      'unnamed files skipped', () async {
    final dir = Directory('${tmp.path}/.hermes/cron/output/job-1')
      ..createSync(recursive: true);
    File('${dir.path}/2026-07-15_08-00-00.md').writeAsStringSync('Tuesday\n');
    File('${dir.path}/2026-07-14_08-00-00.md').writeAsStringSync('Monday\n');
    // Neither of these is a run: an empty result, and a file we can't date.
    File('${dir.path}/2026-07-16_08-00-00.md').writeAsStringSync('   ');
    File('${dir.path}/scratch.md').writeAsStringSync('not a run');

    final runs = await HermesCronServiceImpl(
      '/bin/hermes',
      home: tmp.path,
    ).readOutputs('job-1');

    expect(runs.map((r) => r.text), ['Monday', 'Tuesday']);
    expect(runs.first.at, DateTime(2026, 7, 14, 8));
  });

  test('a task that never ran has no results, and says so rather than '
      'failing', () async {
    final runs = await HermesCronServiceImpl(
      '/bin/hermes',
      home: tmp.path,
    ).readOutputs('never-ran');
    expect(runs, isEmpty);
  });

  group('parseCronOutputTime', () {
    test('reads the run time off Hermes\'s file name', () {
      expect(
        parseCronOutputTime('2026-07-14_08-00-00.md'),
        DateTime(2026, 7, 14, 8),
      );
    });

    test('a name that is not one is skipped, not dated "now" — it would jump '
        'to the top of the results as if it had just happened', () {
      expect(parseCronOutputTime('notes.md'), isNull);
      expect(parseCronOutputTime('2026-07-14.md'), isNull);
      expect(parseCronOutputTime('2026-07-14_08-00-00.txt'), isNull);
    });
  });

  group('TaskDeliveryStore', () {
    test('a corrupt file reads as nothing delivered — a result the user never '
        'saw is re-delivered rather than dropped', () {
      final file = File('${tmp.path}/broken.json')
        ..writeAsStringSync('{ not json');
      expect(TaskDeliveryStore(file: file).load(), isEmpty);
    });

    test('round-trips through disk', () {
      final file = File('${tmp.path}/d.json');
      TaskDeliveryStore(file: file).save({'job-1': DateTime(2026, 7, 14, 8)});

      expect(TaskDeliveryStore(file: file).load(), {
        'job-1': DateTime(2026, 7, 14, 8),
      });
    });
  });

  group('jobIdOfTaskConversation', () {
    test('is the inverse of taskConversationId', () {
      expect(jobIdOfTaskConversation(taskConversationId('abc')), 'abc');
      expect(jobIdOfTaskConversation('task-job-1'), 'job-1');
    });

    test('a chat that is not a task\'s reads as no job — nothing to mark '
        'read', () {
      expect(jobIdOfTaskConversation('mine'), isNull);
      expect(jobIdOfTaskConversation(null), isNull);
      expect(jobIdOfTaskConversation('task-'), isNull);
    });
  });

  group('the "new results" badge', () {
    test('a delivered run marks its task unread, and reading its chat clears '
        'it', () async {
      final h = harness(
        FakeCron(
          jobsJson: _jobsJson(),
          outputs: {
            'job-1': [(at: DateTime(2026, 7, 14, 8), text: 'Digest')],
          },
        ),
      );

      await h.container.read(taskDeliveryProvider.notifier).sweep();
      expect(h.container.read(taskUnreadProvider), contains('job-1'));

      // Opening the chat is what clears it — the shell calls markRead.
      h.container.read(taskUnreadProvider.notifier).markRead('job-1');
      expect(h.container.read(taskUnreadProvider), isNot(contains('job-1')));
    });

    test('a result that lands while its chat is open is not badged — you are '
        'already reading it', () async {
      final h = harness(
        FakeCron(
          jobsJson: _jobsJson(),
          outputs: {
            'job-1': [(at: DateTime(2026, 7, 14, 8), text: 'Digest')],
          },
        ),
      );
      // The task's chat is the one on screen when the run arrives.
      h.container
          .read(chatSessionsProvider.notifier)
          .select(taskConversationId('job-1'));

      await h.container.read(taskDeliveryProvider.notifier).sweep();

      expect(h.container.read(taskUnreadProvider), isNot(contains('job-1')));
    });

    test('the badge outlives a restart — a run missed overnight is still '
        'waiting in the morning', () async {
      final h = harness(
        FakeCron(
          jobsJson: _jobsJson(),
          outputs: {
            'job-1': [(at: DateTime(2026, 7, 14, 8), text: 'Digest')],
          },
        ),
      );
      await h.container.read(taskDeliveryProvider.notifier).sweep();

      // A fresh app (new container, same stores) loads the badge back.
      final next = harness(h.cron);
      expect(next.container.read(taskUnreadProvider), contains('job-1'));
    });
  });

  group('a task chat lands in its project', () {
    test(
      'a project-scoped task delivers its result into that project',
      () async {
        final h = harness(
          FakeCron(
            jobsJson: _jobsJson(),
            outputs: {
              'job-1': [(at: DateTime(2026, 7, 14, 8), text: 'Digest')],
            },
          ),
        );
        h.container
            .read(projectTasksProvider.notifier)
            .assign('job-1', 'proj-1');

        await h.container.read(taskDeliveryProvider.notifier).sweep();

        final chat = h.container
            .read(chatSessionsProvider)
            .conversations
            .singleWhere((c) => c.id == taskConversationId('job-1'));
        expect(chat.projectId, 'proj-1');
      },
    );

    test('a task chat created before the link is reconciled, without waiting '
        'on a new run', () async {
      final h = harness(FakeCron(jobsJson: _jobsJson()));
      // An old chat, saved loose before the app tracked the project link.
      h.chats.save(
        Conversation(
          id: taskConversationId('job-1'),
          title: 'review code',
          model: '',
          createdAt: DateTime(2026, 7, 13),
          updatedAt: DateTime(2026, 7, 13),
        ),
      );
      h.container.read(projectTasksProvider.notifier).assign('job-1', 'proj-1');

      // No new output to deliver — the reconcile still has to run.
      await h.container.read(taskDeliveryProvider.notifier).sweep();

      final chat = h.container
          .read(chatSessionsProvider)
          .conversations
          .singleWhere((c) => c.id == taskConversationId('job-1'));
      expect(chat.projectId, 'proj-1');
      // Re-homing isn't talking in it — the sidebar order (updatedAt) is left be.
      expect(chat.updatedAt, DateTime(2026, 7, 13));
    });
  });

  group('TaskUnreadStore', () {
    test('round-trips a set of job ids through disk', () {
      final file = File('${tmp.path}/u.json');
      TaskUnreadStore(file: file).save({'job-1', 'job-2'});
      expect(TaskUnreadStore(file: file).load(), {'job-1', 'job-2'});
    });

    test('a corrupt or missing file reads as nothing unread — a stray write '
        'never leaves a badge stuck on', () {
      expect(
        TaskUnreadStore(file: File('${tmp.path}/nope.json')).load(),
        isEmpty,
      );

      final broken = File('${tmp.path}/broken-unread.json')
        ..writeAsStringSync('{ not a list');
      expect(TaskUnreadStore(file: broken).load(), isEmpty);
    });
  });
}

/// The chat sender is never reached by a delivery — this makes that explicit.
class _NeverSender implements ChatSender {
  @override
  Stream<ChatSendUpdate> send({
    required NetworkCredential network,
    required String model,
    required List<ChatMessage> history,
    PlaygroundModality modality = PlaygroundModality.text,
    List<MediaAttachment> attachments = const [],
    String? localBaseUrl,
    String? workdir,
    String? conversationId,
    String? instructions,
    bool planFirst = false,
  }) => throw StateError('a delivered result must not call the model');
}
