import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_providers.dart';
import 'package:grid_app/features/agents/logic/adapters/hermes_grid_link.dart';
import 'package:grid_app/features/agents/logic/agent_skill_installer.dart';
import 'package:grid_app/features/agents/logic/adapters/hermes_tool.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/network/logic/client_app_configurator.dart';
import 'package:grid_app/features/network/logic/network_models_provider.dart';
import 'package:grid_app/features/scheduled/logic/job_schedule.dart';
import 'package:grid_app/features/scheduled/logic/job_status.dart';
import 'package:grid_app/features/scheduled/logic/scheduled_job.dart';
import 'package:grid_app/features/scheduled/logic/scheduled_jobs_controller.dart';
import 'package:grid_app/features/scheduled/logic/task_power_controller.dart';
import 'package:grid_app/infrastructure/cli/hermes_config_file.dart';
import 'package:grid_app/infrastructure/cli/hermes_cron_rearm.dart';
import 'package:grid_app/infrastructure/cli/hermes_cron_service.dart';
import 'package:grid_app/infrastructure/cli/hermes_task_policy.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

/// The id Hermes's store gives the task the controller just saved — what the
/// pin and the project link are applied to.
const String kNewJobId = 'new-job';

/// A grid the app has selected, with the models it serves stubbed per-test.
NetworkCredential _network(String id) => NetworkCredential(
  networkId: id,
  name: 'Test grid',
  networkType: 'permissioned',
  lanSignalingUrl: 'http://127.0.0.1:8090',
  accessToken: 'tok-$id',
  refreshToken: '',
  email: 'dev@x.com',
  nodeId: 'node-$id',
  deviceId: 'dev',
  roles: const ['consumer'],
  scopes: const ['consumer:chat'],
  memberEpoch: 1,
  networkEpoch: 1,
  expiresAt: 0,
);

final _grid = _network('grid-foo');

/// A [SelectedNetwork] pinned to a fixed grid, so the controller resolves one
/// without the session/prefs wiring the real notifier reads from disk.
class _FixedSelectedNetwork extends SelectedNetwork {
  _FixedSelectedNetwork(this._fixed);
  final NetworkCredential? _fixed;
  @override
  NetworkCredential? build() => _fixed;
}

/// A fake scheduler: records what it was asked to write, and hands back a store
/// the test controls. No `hermes` process is spawned.
class _FakeCron implements HermesCronService {
  _FakeCron({this.jobsJson, this.failWith});

  String? jobsJson;
  String? failWith;

  /// When set, a re-arm reports it couldn't be applied — the path where Hermes's
  /// own store refuses the change.
  String? rearmFailWith;

  final calls = <String>[];

  /// When set, a pin reports it couldn't be applied.
  String? pinFailWith;

  /// Every re-arm asked for: which model, and whether it was for one task.
  final followed = <({String model, String? onlyJobId})>[];

  /// Every pin asked for, in order — what a task will actually run on.
  final pinned = <({String jobId, String model, bool clearError})>[];
  ({String schedule, String prompt, String name, String? workdir})? created;

  /// The last edit asked for — what a saved task was rewritten to.
  ({String id, String schedule, String prompt, String name})? edited;

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
    // The store grows, as Hermes's does: the controller finds the new task by
    // diffing the ids it knew, and everything it does *after* saving — pinning
    // the model, filing it under a project — depends on that finding it.
    final store =
        jsonDecode(jobsJson ?? '{"jobs": []}') as Map<String, dynamic>;
    final jobs = [...(store['jobs'] as List? ?? const [])];
    jobs.add({
      'id': kNewJobId,
      'name': name,
      'prompt': prompt,
      'schedule': {'kind': 'cron', 'expr': schedule},
      'enabled': true,
    });
    jobsJson = jsonEncode({...store, 'jobs': jobs});
  }

  @override
  Future<void> edit({
    required String id,
    required String schedule,
    required String prompt,
    required String name,
  }) async {
    calls.add('edit:$id');
    _maybeFail();
    edited = (id: id, schedule: schedule, prompt: prompt, name: name);
    // Hermes rewrites the entry in place — same id, same model, same everything
    // the edit didn't name.
    final store =
        jsonDecode(jobsJson ?? '{"jobs": []}') as Map<String, dynamic>;
    final jobs = [
      for (final raw in (store['jobs'] as List? ?? const []))
        if (raw is Map<String, dynamic> && raw['id'] == id)
          {
            ...raw,
            'name': name,
            'prompt': prompt,
            'schedule': {'kind': 'cron', 'expr': schedule},
          }
        else
          raw,
    ];
    jobsJson = jsonEncode({...store, 'jobs': jobs});
  }

  @override
  Future<void> pinModel(
    String jobId,
    String model, {
    bool clearError = false,
  }) async {
    calls.add('pin:$jobId');
    pinned.add((jobId: jobId, model: model, clearError: clearError));
    final message = pinFailWith;
    if (message != null) throw CronRearmException(message);
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
  Future<List<String>> followModel(String model, {String? onlyJobId}) async {
    calls.add('follow:$model');
    followed.add((model: model, onlyJobId: onlyJobId));
    final message = rearmFailWith;
    if (message != null) throw CronRearmException(message);
    // The re-armed task no longer carries the skip that stranded it.
    if (onlyJobId != null) jobsJson = _oneJob;
    return onlyJobId == null ? const [] : [onlyJobId];
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

/// The store after the assistant saved a task of its own, straight through
/// `hermes cron` — no model of its own (it follows the computer's), and the app
/// was never told.
const _twoJobs = '''
{"jobs": [{
  "id": "abc123",
  "name": "Daily digest",
  "prompt": "Summarise my folder",
  "schedule": {"kind": "cron", "expr": "0 8 * * 1-5"},
  "enabled": true
}, {
  "id": "e966a2f83235",
  "name": "fleet-reddit-leads",
  "prompt": "Scan Reddit for leads",
  "schedule": {"kind": "cron", "expr": "30 13 * * *"},
  "enabled": true,
  "model": null,
  "model_snapshot": "DeepSeek-V4-Flash-0731",
  "last_status": "ok"
}]}
''';

/// The same task after Hermes skipped it: the model moved on since it was
/// created, so every run fails closed until something re-arms it.
const _blockedJob = '''
{"jobs": [{
  "id": "abc123",
  "name": "Daily digest",
  "prompt": "Summarise my folder",
  "schedule": {"kind": "cron", "expr": "0 8 * * 1-5"},
  "enabled": true,
  "model": null,
  "model_snapshot": "auto",
  "last_status": "error",
  "last_error": "RuntimeError: Skipped to prevent unintended spend: global inference config drifted since this job was created (model 'auto' -> 'maker/m1'), and this job is unpinned."
}]}
''';

/// A task the app pinned, whose model then stopped answering — the shape the
/// router fallback is for.
const _pinnedFailedJob = '''
{"jobs": [{
  "id": "abc123",
  "name": "Daily digest",
  "prompt": "Summarise my folder",
  "schedule": {"kind": "cron", "expr": "0 8 * * 1-5"},
  "enabled": true,
  "model": "qwen3.6-27b-office",
  "model_snapshot": "qwen3.6-27b-office",
  "last_status": "error",
  "last_error": "RuntimeError: no providers available for this model"
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
    bool gridSelected = true,
    List<String> models = const ['maker/m1'],
  }) {
    final cron = _FakeCron(jobsJson: jobsJson, failWith: failWith);
    final grid = gridSelected ? _grid : null;
    final container = ProviderContainer(
      overrides: [
        hermesCronServiceProvider.overrideWithValue(
          agentInstalled ? cron : null,
        ),
        agentWorkspaceDirProvider.overrideWithValue(workspace),
        // Every Hermes write — the task's powers and the grid it answers with —
        // goes to the temp dir, never the real `~/.hermes`. The null binary
        // path drops the ACP probe too, so pointing the grid never spawns
        // `hermes` to set up web search.
        hermesTaskPolicyProvider.overrideWithValue(
          agentInstalled ? HermesTaskPolicy(home: workspace.path) : null,
        ),
        hermesPathProvider.overrideWithValue(null),
        selectedNetworkProvider.overrideWith(() => _FixedSelectedNetwork(grid)),
        if (grid != null)
          networkModelsForProvider(
            grid.networkId,
          ).overrideWith((ref) => Future.value(models)),
        hermesGridLinkProvider.overrideWith(
          (ref) => HermesGridLink(
            ref,
            config: HermesConfigFile(home: workspace.path),
          ),
        ),
        clientAppConfiguratorProvider.overrideWithValue(
          ClientAppConfigurator(home: workspace.path),
        ),
        agentSkillInstallerProvider.overrideWithValue(
          AgentSkillInstaller(home: workspace.path),
        ),
        chatPrefsStoreProvider.overrideWithValue(
          ChatPrefsStore(file: File('${workspace.path}/app/chat_prefs.json')),
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

  test('a task the assistant created mid-conversation appears on a refresh — '
      'the app is not the only thing that writes to the scheduler', () async {
    final h = harness();
    await h.container.read(scheduledJobsProvider.future);

    // Hermes's store gains a job nobody told the app about: what happens when
    // the user asks the assistant in Chat to schedule something.
    h.cron.jobsJson = _twoJobs;
    await h.container.read(scheduledJobsProvider.notifier).refresh();

    final jobs = h.container.read(scheduledJobsProvider).value!;
    expect(jobs.map((job) => job.name), ['Daily digest', 'fleet-reddit-leads']);
  });

  test('a refresh that finds nothing new leaves the list alone, so the screen '
      'does not rebuild every sweep', () async {
    final h = harness();
    final before = await h.container.read(scheduledJobsProvider.future);

    await h.container.read(scheduledJobsProvider.notifier).refresh();

    expect(h.container.read(scheduledJobsProvider).value, same(before));
  });

  test('creating a task hands Hermes a cron expression and the Projects '
      'folder — so the task can actually read the user\'s files', () async {
    final h = harness();
    await h.container.read(scheduledJobsProvider.future);

    final result = await h.container
        .read(scheduledJobsProvider.notifier)
        .create(
          model: 'maker/m1',
          name: 'Weekly review',
          prompt: 'Summarise the week',
          schedule: const JobSchedule(
            cadence: JobCadence.chosenDays,
            hour: 16,
            minute: 0,
            days: {DateTime.friday},
          ),
        );

    expect(result.error, isNull);
    expect(h.cron.created?.schedule, '0 16 * * 5');
    expect(h.cron.created?.name, 'Weekly review');
    expect(h.cron.created?.workdir, workspace.path);
  });

  test('an interval task is sent as an `every Nm` Hermes understands, not a '
      'cron line', () async {
    final h = harness();
    await h.container.read(scheduledJobsProvider.future);

    await h.container
        .read(scheduledJobsProvider.notifier)
        .create(
          model: 'maker/m1',
          name: 'Inbox check',
          prompt: 'Any new mail?',
          schedule: const JobSchedule(cadence: JobCadence.every30Min),
        );

    expect(h.cron.created?.schedule, 'every 30m');
  });

  test('an interval job reads back with its schedule, not a blank row — Hermes '
      'stores it as a display string with no cron expr', () async {
    const intervalJob = '''
{"jobs": [{
  "id": "iv1",
  "name": "Inbox check",
  "prompt": "Any new mail?",
  "schedule": {"kind": "interval", "minutes": 120, "display": "every 120m"},
  "schedule_display": "every 120m",
  "enabled": true
}]}
''';
    final h = harness(jobsJson: intervalJob);

    final jobs = await h.container.read(scheduledJobsProvider.future);

    expect(jobs.single.cron, 'every 120m');
    expect(describeJobSchedule(jobs.single.cron), 'Every 2 hours');
  });

  test('a new task is pinned to the model the user picked, so changing the '
      'model in Chat stops stranding it', () async {
    final h = harness();
    await h.container.read(scheduledJobsProvider.future);
    const daily = JobSchedule(cadence: JobCadence.everyDay, hour: 8, minute: 0);

    final result = await h.container
        .read(scheduledJobsProvider.notifier)
        .create(
          model: 'qwen3.6-27b-office',
          name: 'Digest',
          prompt: 'p',
          schedule: daily,
        );

    expect(result.error, isNull);
    expect(h.cron.pinned.single.jobId, kNewJobId);
    expect(h.cron.pinned.single.model, 'qwen3.6-27b-office');
  });

  test(
    'a task cannot be created on a model the assistant cannot answer with — '
    "the run would come back as the tool call, and be recorded as ok",
    () async {
      final h = harness();
      await h.container.read(scheduledJobsProvider.future);

      final result = await h.container
          .read(scheduledJobsProvider.notifier)
          .create(
            model: 'claude:claude-sonnet-5',
            name: 'Digest',
            prompt: 'p',
            schedule: const JobSchedule(
              cadence: JobCadence.everyDay,
              hour: 8,
              minute: 0,
            ),
          );

      expect(result.error, kHermesCannotServeSeatModel);
      expect(h.cron.created, isNull);
      expect(h.cron.pinned, isEmpty);
    },
  );

  group('editing a saved task', () {
    /// The form's save, over the task the fixtures carry.
    Future<String?> edit(
      ProviderContainer container, {
      String model = 'maker/m1',
      String prompt = 'Summarise my folder, and say what changed',
      JobSchedule schedule = const JobSchedule(
        cadence: JobCadence.everyDay,
        hour: 7,
        minute: 30,
      ),
    }) => container
        .read(scheduledJobsProvider.notifier)
        .edit(
          id: 'abc123',
          name: 'Daily digest',
          prompt: prompt,
          schedule: schedule,
          model: model,
        );

    test('rewrites what the task does and when — the same task, so the results '
        'it has already produced survive the change', () async {
      final h = harness();
      await h.container.read(scheduledJobsProvider.future);

      final error = await edit(h.container);

      expect(error, isNull);
      expect(h.cron.edited?.id, 'abc123');
      expect(h.cron.edited?.schedule, '30 7 * * *');
      expect(
        h.cron.edited?.prompt,
        'Summarise my folder, and say what changed',
      );
      expect(
        h.cron.calls,
        isNot(contains('create')),
        reason: 'an edit that re-creates the task loses its history',
      );
      final saved = h.container.read(scheduledJobsProvider).value!.single;
      expect(saved.id, 'abc123');
      expect(
        saved.cron,
        '30 7 * * *',
        reason:
            'the screen must show the new '
            'schedule without a reload',
      );
    });

    test('leaves the model alone when the user did not touch it — an edit to '
        'the wording must not clear a failure nobody has read yet', () async {
      final h = harness(jobsJson: _pinnedFailedJob);
      await h.container.read(scheduledJobsProvider.future);

      final error = await edit(h.container, model: 'qwen3.6-27b-office');

      expect(error, isNull);
      expect(h.cron.pinned, isEmpty);
    });

    test('re-pins the task when the form comes back with another model, so '
        'what runs is what the user just picked', () async {
      final h = harness(jobsJson: _pinnedFailedJob);
      await h.container.read(scheduledJobsProvider.future);

      final error = await edit(h.container, model: 'maker/m1');

      expect(error, isNull);
      expect(h.cron.pinned.single.jobId, 'abc123');
      expect(h.cron.pinned.single.model, 'maker/m1');
      expect(
        h.cron.pinned.single.clearError,
        isTrue,
        reason: 'picking a model is the fix for the run that blamed one',
      );
    });

    test('a model only another vendor\'s CLI can drive is refused before '
        'anything is written', () async {
      final h = harness();
      await h.container.read(scheduledJobsProvider.future);

      final error = await edit(h.container, model: 'claude:claude-sonnet-5');

      expect(error, contains('Switch the assistant'));
      expect(h.cron.edited, isNull, reason: 'nothing may be half-written');
    });

    test('a scheduler that refuses the change hands back its own line, not a '
        'success', () async {
      final h = harness(failWith: 'no such job: abc123');
      await h.container.read(scheduledJobsProvider.future);

      expect(await edit(h.container), 'no such job: abc123');
    });
  });

  test('what a task is allowed to do is settled before it is saved — there is '
      'nobody to ask at 8am', () async {
    final h = harness();
    await h.container.read(scheduledJobsProvider.future);

    await h.container
        .read(scheduledJobsProvider.notifier)
        .create(
          model: 'maker/m1',
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

  test(
    'saving a task points Hermes at the selected grid, so it has a model to '
    'run with instead of failing at 8am with "no model configured"',
    () async {
      final h = harness();
      await h.container.read(scheduledJobsProvider.future);

      final result = await h.container
          .read(scheduledJobsProvider.notifier)
          .create(
            model: 'maker/m1',
            name: 'Digest',
            prompt: 'Summarise',
            schedule: const JobSchedule(
              cadence: JobCadence.everyDay,
              hour: 8,
              minute: 0,
            ),
          );

      expect(result.error, isNull);
      expect(h.cron.created, isNotNull);
      expect(
        await HermesConfigFile(
          home: workspace.path,
        ).valueAt(['model', 'default']),
        'maker/m1',
        reason: 'the task runs on the grid the app has selected',
      );
    },
  );

  test('a task that could only ever fail is refused, not saved — no grid '
      'picked and no model configured is the "no model configured" bug waiting '
      'to happen', () async {
    final h = harness(gridSelected: false);
    await h.container.read(scheduledJobsProvider.future);

    final result = await h.container
        .read(scheduledJobsProvider.notifier)
        .create(
          model: 'maker/m1',
          name: 'Digest',
          prompt: 'Summarise',
          schedule: const JobSchedule(
            cadence: JobCadence.everyDay,
            hour: 8,
            minute: 0,
          ),
        );

    expect(result.error, contains('Pick a grid'));
    expect(result.id, isNull);
    expect(
      h.cron.created,
      isNull,
      reason: 'nothing was written to the scheduler',
    );
  });

  test('a grid sharing no AI yet is refused with what to do, not a task that '
      'answers nothing', () async {
    final h = harness(models: const []);
    await h.container.read(scheduledJobsProvider.future);

    final result = await h.container
        .read(scheduledJobsProvider.notifier)
        .create(
          model: 'maker/m1',
          name: 'Digest',
          prompt: 'Summarise',
          schedule: const JobSchedule(
            cadence: JobCadence.everyDay,
            hour: 8,
            minute: 0,
          ),
        );

    expect(result.error, contains('This computer'));
    expect(h.cron.created, isNull);
  });

  test('a grid whose only AI is another vendor\'s CLI seat is refused with the '
      'fix that works — the assistant, not the sharing', () async {
    final h = harness(models: const ['claude:claude-sonnet-5']);
    await h.container.read(scheduledJobsProvider.future);

    final result = await h.container
        .read(scheduledJobsProvider.notifier)
        .create(
          model: 'maker/m1',
          name: 'Digest',
          prompt: 'Summarise',
          schedule: const JobSchedule(
            cadence: JobCadence.everyDay,
            hour: 8,
            minute: 0,
          ),
        );

    expect(result.error, contains('Switch the assistant'));
    expect(h.cron.created, isNull);
  });

  test(
    'a task runs on the model Hermes can answer with, never the seat the '
    'grid also shares — an 8am run has nobody to notice the difference',
    () async {
      final h = harness(models: const ['claude:claude-sonnet-5', 'maker/m1']);
      await h.container.read(scheduledJobsProvider.future);

      await h.container
          .read(scheduledJobsProvider.notifier)
          .create(
            model: 'maker/m1',
            name: 'Digest',
            prompt: 'Summarise',
            schedule: const JobSchedule(
              cadence: JobCadence.everyDay,
              hour: 8,
              minute: 0,
            ),
          );
      await Future<void>.delayed(Duration.zero);

      expect(h.cron.created, isNotNull);
      expect(h.cron.followed.first.model, 'maker/m1');
    },
  );

  test(
    'a task still saves when the user configured Hermes themselves — no '
    'grid picked is no reason to refuse a model that is already there',
    () async {
      // A config that already names a model: Hermes has something to answer with,
      // whoever wrote it, so the task is not blocked.
      await HermesConfigFile(home: workspace.path).edit(
        (editor) =>
            HermesConfigFile.upsert(editor, ['model', 'default'], 'mine/own'),
      );
      final h = harness(gridSelected: false);
      await h.container.read(scheduledJobsProvider.future);

      final result = await h.container
          .read(scheduledJobsProvider.notifier)
          .create(
            model: 'maker/m1',
            name: 'Digest',
            prompt: 'Summarise',
            schedule: const JobSchedule(
              cadence: JobCadence.everyDay,
              hour: 8,
              minute: 0,
            ),
          );

      expect(result.error, isNull);
      expect(h.cron.created, isNotNull);
    },
  );

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
          model: 'maker/m1',
          name: 'Daily digest',
          prompt: 'Summarise',
          schedule: const JobSchedule(
            cadence: JobCadence.everyDay,
            hour: 8,
            minute: 0,
          ),
        );

    // Assert on the cron toolset list — what a scheduled run actually loads —
    // not the whole file: pointing Hermes at the grid also writes a top-level
    // chat `toolsets:` that does include `terminal`, but that key never gates
    // cron. The limit that matters is `platform_toolsets.cron`.
    expect(
      await HermesTaskPolicy(home: workspace.path).read(),
      TaskPower.noCommands,
    );
    final cronTools = await HermesConfigFile(
      home: workspace.path,
    ).valueAt(['platform_toolsets', 'cron']);
    expect(cronTools, isNot(contains('terminal')));
    expect(cronTools, contains('file'), reason: 'it still reads your project');
    final config = File(
      '${workspace.path}/.hermes/config.yaml',
    ).readAsStringSync();
    expect(config, contains('cron_mode: deny'));
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

  group('a task stranded by a model change', () {
    /// Hermes already answers with a model, so the action has one to hand the
    /// scheduler without going through a grid.
    Future<void> configureModel() =>
        HermesConfigFile(home: workspace.path).edit(
          (editor) =>
              HermesConfigFile.upsert(editor, ['model', 'default'], 'mine/own'),
        );

    test('goes back on schedule in one action, on the model this computer '
        'uses now — its results are not thrown away', () async {
      await configureModel();
      final h = harness(jobsJson: _blockedJob);
      await h.container.read(scheduledJobsProvider.future);
      expect(
        jobStatusOf(h.container.read(scheduledJobsProvider).value!.single),
        JobStatus.blocked,
      );

      final error = await h.container
          .read(scheduledJobsProvider.notifier)
          .useCurrentModel('abc123');

      expect(error, isNull);
      expect(h.cron.followed.single.model, 'mine/own');
      expect(
        h.cron.followed.single.onlyJobId,
        'abc123',
        reason: 'only the task the user asked about is touched',
      );
      expect(
        jobStatusOf(h.container.read(scheduledJobsProvider).value!.single),
        JobStatus.running,
        reason: 'the screen must stop saying "won\'t run" once it will',
      );
    });

    test('with no model set for tasks, the action says what to fix instead of '
        'pretending it worked', () async {
      final h = harness(jobsJson: _blockedJob);
      await h.container.read(scheduledJobsProvider.future);

      final error = await h.container
          .read(scheduledJobsProvider.notifier)
          .useCurrentModel('abc123');

      expect(error, contains('no AI model set'));
      expect(h.cron.followed, isEmpty);
    });

    test('a config left naming a CLI seat is refused, not armed onto the task '
        '— that pairing comes back as raw tool-call JSON, marked ok', () async {
      await HermesConfigFile(home: workspace.path).edit(
        (editor) => HermesConfigFile.upsert(editor, [
          'model',
          'default',
        ], 'claude:claude-sonnet-5'),
      );
      final h = harness(jobsJson: _blockedJob);
      await h.container.read(scheduledJobsProvider.future);

      final error = await h.container
          .read(scheduledJobsProvider.notifier)
          .useCurrentModel('abc123');

      expect(error, kHermesCannotServeSeatModel);
      expect(h.cron.followed, isEmpty);
    });

    test('a scheduler that refuses the change comes back as a line to show, '
        'not a silent success', () async {
      await configureModel();
      final h = harness(jobsJson: _blockedJob);
      h.cron.rearmFailWith = 'ValueError: no such job';
      await h.container.read(scheduledJobsProvider.future);

      final error = await h.container
          .read(scheduledJobsProvider.notifier)
          .useCurrentModel('abc123');

      expect(error, contains('ValueError: no such job'));
    });

    test(
      'a pinned task is re-pinned rather than re-armed — a re-arm skips a '
      'pinned job, so the button would report a success it never had',
      () async {
        await configureModel();
        final h = harness(jobsJson: _pinnedFailedJob);
        await h.container.read(scheduledJobsProvider.future);

        final error = await h.container
            .read(scheduledJobsProvider.notifier)
            .useCurrentModel('abc123');

        expect(error, isNull);
        expect(h.cron.followed, isEmpty);
        expect(h.cron.pinned.single.model, 'mine/own');
        expect(
          h.cron.pinned.single.clearError,
          isTrue,
          reason: 'a task that will now run must stop saying it will not',
        );
      },
    );
  });

  group('a task whose model stopped answering', () {
    test('is moved to the grid\'s router, with the failed run cleared — a task '
        'nobody watches must not fail every morning into a file', () async {
      final h = harness(jobsJson: _pinnedFailedJob);
      await h.container.read(scheduledJobsProvider.future);

      final moved = await h.container
          .read(scheduledJobsProvider.notifier)
          .fallbackToAuto({'auto', 'maker/m1'});

      expect(moved, ['abc123']);
      expect(h.cron.pinned.single.model, 'auto');
      expect(h.cron.pinned.single.clearError, isTrue);
    });

    test('is left alone while the model is still served and the last run was '
        'fine — a pinned model is the user\'s choice', () async {
      final h = harness();
      await h.container.read(scheduledJobsProvider.future);

      final moved = await h.container
          .read(scheduledJobsProvider.notifier)
          .fallbackToAuto({'auto', 'maker/m1'});

      expect(moved, isEmpty);
      expect(h.cron.pinned, isEmpty);
    });
  });

  test('switching the model the assistant uses lets the saved tasks follow it '
      '— otherwise the scheduler skips every one of them from then on', () async {
    final h = harness(jobsJson: _blockedJob);
    await h.container.read(scheduledJobsProvider.future);

    // Saving a task points Hermes at the selected grid, which is where the model
    // changes. The re-arm rides along without holding that up, so let the
    // microtask it was fired on run before looking.
    await h.container
        .read(scheduledJobsProvider.notifier)
        .create(
          model: 'maker/m1',
          name: 'Digest',
          prompt: 'Summarise',
          schedule: const JobSchedule(
            cadence: JobCadence.everyDay,
            hour: 8,
            minute: 0,
          ),
        );
    await Future<void>.delayed(Duration.zero);

    expect(h.cron.followed, isNotEmpty);
    expect(h.cron.followed.first.model, 'maker/m1');
    expect(
      h.cron.followed.first.onlyJobId,
      isNull,
      reason: 'every stranded task follows the new model, not just one',
    );
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
