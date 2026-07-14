import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/agent_providers.dart';
import 'package:grid_app/features/scheduled/logic/job_schedule.dart';
import 'package:grid_app/features/scheduled/logic/scheduled_job.dart';
import 'package:grid_app/features/scheduled/logic/scheduled_jobs_controller.dart';
import 'package:grid_app/features/scheduled/logic/task_power_controller.dart';
import 'package:grid_app/infrastructure/cli/hermes_cron_service.dart';
import 'package:grid_app/infrastructure/cli/hermes_task_policy.dart';

/// A fake scheduler: records what it was asked to write, and hands back a store
/// the test controls. No `hermes` process is spawned.
class _FakeCron implements HermesCronService {
  _FakeCron({this.jobsJson, this.failWith});

  String? jobsJson;
  String? failWith;

  final calls = <String>[];
  ({String schedule, String prompt, String name, String? workdir})? created;

  void _maybeFail() {
    final message = failWith;
    if (message != null) throw HermesCronException(message);
  }

  @override
  Future<String?> readJobsJson() async => jobsJson;

  @override
  Future<List<CronOutput>> readOutputs(String jobId) async => const [];

  @override
  Future<void> create({
    required String schedule,
    required String prompt,
    required String name,
    String? workdir,
  }) async {
    calls.add('create');
    _maybeFail();
    created = (
      schedule: schedule,
      prompt: prompt,
      name: name,
      workdir: workdir,
    );
  }

  @override
  Future<void> pause(String id) async {
    calls.add('pause:$id');
    _maybeFail();
  }

  @override
  Future<void> resume(String id) async {
    calls.add('resume:$id');
    _maybeFail();
  }

  @override
  Future<void> remove(String id) async {
    calls.add('remove:$id');
    _maybeFail();
    jobsJson = '{"jobs": []}';
  }

  @override
  Future<void> runNow(String id) async {
    calls.add('run:$id');
    _maybeFail();
  }

  @override
  Future<bool> schedulerRunning() async => true;

  @override
  Future<void> startScheduler() async => calls.add('start');
}

const _oneJob = '''
{"jobs": [{
  "id": "abc123",
  "name": "Daily digest",
  "prompt": "Summarise my folder",
  "schedule": {"kind": "cron", "expr": "0 8 * * 1-5"},
  "enabled": true,
  "next_run_at": "2026-07-15T08:00:00+07:00",
  "last_run_at": null,
  "last_status": null,
  "last_error": null
}]}
''';

void main() {
  late Directory workspace;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('grid_cron_test');
  });
  tearDown(() => workspace.delete(recursive: true));

  ({ProviderContainer container, _FakeCron cron}) harness({
    String? jobsJson = _oneJob,
    String? failWith,
    bool agentInstalled = true,
  }) {
    final cron = _FakeCron(jobsJson: jobsJson, failWith: failWith);
    final container = ProviderContainer(
      overrides: [
        hermesCronServiceProvider.overrideWithValue(
          agentInstalled ? cron : null,
        ),
        agentWorkspaceDirProvider.overrideWithValue(workspace),
        // What a task is allowed to do is written into Hermes's config — point
        // that at the temp dir, never the real `~/.hermes`.
        hermesTaskPolicyProvider.overrideWithValue(
          agentInstalled ? HermesTaskPolicy(home: workspace.path) : null,
        ),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, cron: cron);
  }

  test('reads the tasks out of Hermes\'s own store', () async {
    final h = harness();

    final jobs = await h.container.read(scheduledJobsProvider.future);

    expect(jobs, hasLength(1));
    expect(jobs.single.name, 'Daily digest');
    expect(jobs.single.cron, '0 8 * * 1-5');
    expect(jobs.single.enabled, isTrue);
  });

  test('an untouched scheduler reads as no tasks, not an error', () async {
    final h = harness(jobsJson: null);
    expect(await h.container.read(scheduledJobsProvider.future), isEmpty);
  });

  test('creating a task hands Hermes a cron expression and the Projects '
      'folder — so the task can actually read the user\'s files', () async {
    final h = harness();
    await h.container.read(scheduledJobsProvider.future);

    final error = await h.container
        .read(scheduledJobsProvider.notifier)
        .create(
          name: 'Weekly review',
          prompt: 'Summarise the week',
          schedule: const JobSchedule(
            cadence: JobCadence.weekly,
            hour: 16,
            minute: 0,
            weekday: DateTime.friday,
          ),
        );

    expect(error, isNull);
    expect(h.cron.created?.schedule, '0 16 * * 5');
    expect(h.cron.created?.name, 'Weekly review');
    expect(h.cron.created?.workdir, workspace.path);
  });

  test('what a task is allowed to do is settled before it is saved — there is '
      'nobody to ask at 8am', () async {
    final h = harness();
    await h.container.read(scheduledJobsProvider.future);

    await h.container
        .read(scheduledJobsProvider.notifier)
        .create(
          name: 'Daily digest',
          prompt: 'Summarise',
          schedule: const JobSchedule(
            cadence: JobCadence.everyDay,
            hour: 8,
            minute: 0,
          ),
        );

    // Hermes's own config now says what the screen said it would.
    final config = File('${workspace.path}/.hermes/config.yaml');
    expect(config.existsSync(), isTrue);
    expect(config.readAsStringSync(), contains('cron_mode: approve'));
    expect(
      await h.container.read(taskPowerProvider.future),
      TaskPower.fullAccess,
    );
  });

  test('a task saved with "no commands" leaves the scheduler with no terminal '
      'at all — the limit is real, not a promise', () async {
    final h = harness();
    await h.container.read(scheduledJobsProvider.future);

    await h.container
        .read(taskPowerProvider.notifier)
        .set(TaskPower.noCommands);
    await h.container
        .read(scheduledJobsProvider.notifier)
        .create(
          name: 'Daily digest',
          prompt: 'Summarise',
          schedule: const JobSchedule(
            cadence: JobCadence.everyDay,
            hour: 8,
            minute: 0,
          ),
        );

    final config = File(
      '${workspace.path}/.hermes/config.yaml',
    ).readAsStringSync();
    expect(config, contains('cron_mode: deny'));
    expect(config, isNot(contains('terminal')));
    expect(config, contains('file'), reason: 'it still reads your project');
  });

  test(
    'a scheduler failure comes back as a line to show, not a crash',
    () async {
      final h = harness(failWith: 'hermes: bad schedule');
      await h.container.read(scheduledJobsProvider.future);

      final error = await h.container
          .read(scheduledJobsProvider.notifier)
          .pause('abc123');

      expect(error, 'hermes: bad schedule');
    },
  );

  test('with no agent installed, every action says so instead of failing '
      'silently', () async {
    final h = harness(agentInstalled: false);

    expect(await h.container.read(scheduledJobsProvider.future), isEmpty);
    final error = await h.container
        .read(scheduledJobsProvider.notifier)
        .runNow('abc123');
    expect(error, contains("isn't set up to run tasks"));
  });

  test('deleting the open task closes the detail pane with it', () async {
    final h = harness();
    await h.container.read(scheduledJobsProvider.future);
    h.container.read(selectedJobIdProvider.notifier).select('abc123');

    await h.container.read(scheduledJobsProvider.notifier).remove('abc123');

    expect(h.container.read(selectedJobIdProvider), isNull);
    expect(h.container.read(scheduledJobsProvider).value, isEmpty);
  });

  group('parseScheduledJobs', () {
    test('a job saved without a name is listed by its prompt, never blank', () {
      final jobs = parseScheduledJobs(
        '{"jobs": [{"id": "x1", "prompt": "Water the plants", '
        '"schedule": {"expr": "0 9 * * *"}}]}',
      );

      expect(jobs.single.name, 'Water the plants');
      expect(jobs.single.enabled, isTrue);
    });

    test('a malformed entry is skipped, the rest still show', () {
      final jobs = parseScheduledJobs(
        '{"jobs": ["nope", {"id": "x1", "prompt": "p", '
        '"schedule": {"expr": "0 9 * * *"}}]}',
      );

      expect(jobs.map((j) => j.id).toList(), ['x1']);
    });

    test('a failed run is flagged, so a broken task cannot look healthy', () {
      final jobs = parseScheduledJobs(
        '{"jobs": [{"id": "x1", "name": "n", "prompt": "p", '
        '"schedule": {"expr": "0 9 * * *"}, "last_error": "boom"}]}',
      );

      expect(jobs.single.failed, isTrue);
      expect(jobs.single.lastError, 'boom');
    });
  });
}
