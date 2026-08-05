import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../../core/text_preview.dart';
import '../../../infrastructure/cli/hermes_cron_service.dart';
import '../../../infrastructure/platform/desktop_notifier.dart';
import '../../../infrastructure/platform/window_focus.dart';
import '../../chat/logic/chat_sessions_controller.dart';
import '../../network/logic/network_models_provider.dart';
import '../../projects/logic/project_tasks_store.dart';
import 'cron_output.dart';
import 'job_schedule.dart';
import 'scheduled_job.dart';
import 'scheduled_jobs_controller.dart';
import 'task_inbox_store.dart';
import 'task_model_fallback.dart';
import 'task_unread_store.dart';

/// Prefix on a task chat's id, the seam between it and the job id it carries.
const String _kTaskChatPrefix = 'task-';

/// The conversation a task's results land in. One per task, so a daily digest
/// reads as a thread rather than a pile of unrelated chats.
String taskConversationId(String jobId) => '$_kTaskChatPrefix$jobId';

/// The job id behind a task chat's [conversationId], or null when it isn't one
/// — the inverse of [taskConversationId], so opening a chat can find the task to
/// mark read without the chat feature having to know the id scheme.
String? jobIdOfTaskConversation(String? conversationId) {
  if (conversationId == null || !conversationId.startsWith(_kTaskChatPrefix)) {
    return null;
  }
  final jobId = conversationId.substring(_kTaskChatPrefix.length);
  return jobId.isEmpty ? null : jobId;
}

/// A result as it reads in the chat: when the task ran, then what it found.
///
/// The stamp isn't decoration — three mornings of the same digest are otherwise
/// indistinguishable, and a result from a run the user missed would look like it
/// just arrived. The answer only ([cronOutputBody]), not the job-id/schedule
/// metadata Hermes wraps it in — the stamp above already carries the timing.
String taskResultMessage(CronOutput run) =>
    '*Ran ${jobTimeLabel(run.at)}*\n\n${cronOutputBody(run.text)}';

/// How often the app looks for runs that have finished.
///
/// The scheduler is Hermes's, not the app's: it runs jobs whether the app is open
/// or not, and simply leaves the result in a file. So the app has to come back and
/// look — there's nothing to push it.
const Duration kTaskSweepInterval = Duration(seconds: 30);

/// Overridable so tests don't wait on a real clock.
final taskSweepIntervalProvider = Provider<Duration>(
  (ref) => kTaskSweepInterval,
);

/// Remembers the last run of each task that was put into Chat, so a result is
/// delivered once — not again on every launch, and not again every 30 seconds.
///
/// Persisted as `~/.grid/app/task_delivery.json`. App-owned and lenient like the
/// other app stores: an unreadable file reads as "nothing delivered yet", which
/// re-delivers rather than silently dropping a result the user never saw.
class TaskDeliveryStore {
  TaskDeliveryStore({File? file}) : _file = file ?? GridPaths.taskDeliveryFile;

  final File _file;

  Map<String, DateTime> load() {
    try {
      if (!_file.existsSync()) return const {};
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! Map) return const {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String &&
              DateTime.tryParse('${entry.value}') != null)
            entry.key as String: DateTime.parse('${entry.value}'),
      };
    } on Object {
      return const {};
    }
  }

  void save(Map<String, DateTime> delivered) {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        for (final entry in delivered.entries)
          entry.key: entry.value.toIso8601String(),
      }),
      flush: true,
    );
  }
}

/// Overridable so tests point at a temp file and never touch the real `~/.grid`.
final taskDeliveryStoreProvider = Provider<TaskDeliveryStore>(
  (ref) => TaskDeliveryStore(),
);

/// Carries finished scheduled-task results into the Chat tab.
///
/// Hermes runs the tasks and writes each result to a file — that's all `--deliver
/// local` means, and left there the user would never see it. This watches for new
/// results and delivers them into the task's own chat, so "the answer is waiting
/// when you come back" is actually true.
final taskDeliveryProvider =
    NotifierProvider<TaskDeliveryController, List<String>>(
      TaskDeliveryController.new,
    );

class TaskDeliveryController extends Notifier<List<String>> {
  Timer? _timer;
  bool _sweeping = false;

  /// The ids of tasks whose results have arrived since the app started — what the
  /// sidebar could badge. Empty until something lands.
  @override
  List<String> build() {
    ref.onDispose(_stop);
    return const [];
  }

  /// Start watching. Called once, from the shell — not from `build`, so nothing
  /// is mutated while the app is still building its first frame.
  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(
      ref.read(taskSweepIntervalProvider),
      (_) => unawaited(sweep()),
    );
    unawaited(sweep());
  }

  /// Collect every result that hasn't been delivered yet, and put it in the
  /// task's chat. Safe to call at any time; overlapping sweeps are dropped.
  Future<void> sweep() async {
    final cron = ref.read(hermesCronServiceProvider);
    if (cron == null || _sweeping) return;
    _sweeping = true;
    try {
      // Wait for the saved chats to be read before deciding a task's chat is
      // missing: [ChatSessionsController.deliverFromAgent] starts one when it
      // can't find it, and a sweep that ran during the read would start a
      // *second* one over the same id — the day's result replacing the history
      // it should have been appended to.
      await ref.read(chatSessionsProvider.notifier).restored;
      final jobs = await ref.read(scheduledJobsProvider.future);
      final delivered = {...ref.read(taskDeliveryStoreProvider).load()};
      final links = ref.read(projectTasksProvider);
      final chat = ref.read(chatSessionsProvider.notifier);
      final arrived = <String>[];

      for (final job in jobs) {
        final projectId = links[job.id];
        // Keep the task's chat under its project even when there's no new run to
        // deliver — a chat created before the app tracked the link would sit
        // loose forever otherwise.
        if (projectId != null) {
          chat.linkToProject(taskConversationId(job.id), projectId);
        }
        final last = await _deliver(job, cron, delivered[job.id], projectId);
        if (last == null) continue;
        delivered[job.id] = last.at;
        arrived.add(job.id);
        // Two ways to find out what arrived without opening it: the row in the
        // Scheduled list, and a banner if the user is elsewhere.
        ref
            .read(taskInboxProvider.notifier)
            .record(
              job.id,
              TaskResultDigest(summary: last.summary, at: last.at),
            );
        _announce(job, last.summary);
      }

      // A task whose model has stopped working goes to the grid's router rather
      // than failing every morning into a file nobody reads. Done here because
      // this is the one loop that runs whether or not the Tasks screen is open.
      await ref.read(scheduledJobsProvider.notifier).fallbackToAuto(_served());

      if (arrived.isEmpty) return;
      ref.read(taskDeliveryStoreProvider).save(delivered);
      // Badge each task that just delivered, so the sidebar and the Scheduled
      // list say a result is waiting until the user opens it.
      ref.read(taskUnreadProvider.notifier).markUnread(arrived);
      state = [...state, ...arrived];
    } on Object {
      // A scheduler that can't be read is the Scheduled screen's problem to
      // report; a background sweep must not take the app down with it.
      return;
    } finally {
      _sweeping = false;
    }
  }

  /// What the open grid is serving, as far as the app already knows.
  ///
  /// Read, never fetched: this runs every 30 seconds, and a relay call on that
  /// clock would be a poll nobody asked for. An answer that hasn't loaded comes
  /// back empty, which [autoFallbackTargets] reads as "don't know" rather than
  /// as "every model is gone".
  ///
  /// Through [servedModelIdsProvider] so that "hasn't loaded" means the first
  /// answer only: a tick that landed while the list was being re-read used to
  /// see nothing served and retarget a job that was fine.
  Set<String> _served() => ref.read(servedModelIdsProvider).toSet();

  /// Deliver [job]'s results newer than [since] into its chat, homing it under
  /// [projectId] when the task belongs to a project. Returns when the newest one
  /// ran and the line it opens with, or null when there was nothing new.
  Future<({DateTime at, String summary})?> _deliver(
    ScheduledJob job,
    HermesCronService cron,
    DateTime? since,
    String? projectId,
  ) async {
    final runs = await cron.readOutputs(job.id);
    final fresh = [
      for (final run in runs)
        if (since == null || run.at.isAfter(since)) run,
    ];
    if (fresh.isEmpty) return null;

    final chat = ref.read(chatSessionsProvider.notifier);
    for (final run in fresh) {
      chat.deliverFromAgent(
        id: taskConversationId(job.id),
        title: job.name,
        text: taskResultMessage(run),
        at: run.at,
        projectId: projectId,
      );
    }
    final last = fresh.last;
    return (at: last.at, summary: firstLinePreview(cronOutputBody(last.text)));
  }

  /// Tell the desktop a task has an answer waiting.
  ///
  /// This is the whole point of a scheduled task: it ran at 3am and the app was
  /// behind another window, so the badge in a sidebar nobody is looking at is
  /// not delivery. Suppressed only when the user is already reading that task's
  /// chat with the window in front — see [notificationIsWorthIt].
  void _announce(ScheduledJob job, String summary) {
    final chatId = taskConversationId(job.id);
    final worthIt = notificationIsWorthIt(
      appFocused: ref.read(windowFocusedProvider),
      userIsLookingAtIt: ref.read(chatSessionsProvider).activeId == chatId,
    );
    if (!worthIt) return;
    unawaited(
      ref
          .read(desktopNotifierProvider)
          .show(
            DesktopNotification(
              title: job.name,
              // The answer's own first line, not "the task finished" — the
              // second tells the user nothing they didn't already schedule.
              body: summary.isEmpty
                  ? 'Finished with nothing to report.'
                  : summary,
              opens: chatId,
            ),
          ),
    );
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }
}
