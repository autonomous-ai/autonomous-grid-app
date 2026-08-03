import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/hermes_cron_rearm.dart';
import '../../../infrastructure/cli/hermes_cron_service.dart';
import '../../agent/logic/agent_providers.dart';
import '../../agent/logic/hermes_grid_link.dart';
import '../../projects/logic/project_tasks_store.dart';
import 'job_schedule.dart';
import 'scheduled_job.dart';
import 'task_delivery.dart';
import 'task_power_controller.dart';

/// Whether the thing that actually fires jobs is alive. Jobs are saved either
/// way, so this is what lets the screen tell the truth: "saved, but nothing will
/// run until the scheduler is on".
final schedulerRunningProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(hermesCronServiceProvider);
  return service != null && await service.schedulerRunning();
});

/// What a task's runs have produced, oldest first — read back from Hermes, which
/// writes one file per run. Refetches whenever a sweep delivers something new, so
/// the screen and the chat never disagree about what the task has found.
final jobOutputsProvider = FutureProvider.family<List<CronOutput>, String>((
  ref,
  jobId,
) async {
  ref.watch(taskDeliveryProvider);
  final service = ref.watch(hermesCronServiceProvider);
  if (service == null) return const [];
  return service.readOutputs(jobId);
});

/// One finished run, tagged with the task it belongs to — the unit the "recent
/// activity" view is built from.
typedef JobRun = ({String jobId, String jobName, DateTime at, String text});

/// The latest runs across every task, newest first — what the right pane shows
/// before a task is picked, so an empty selection still proves the assistant is
/// working. Rebuilds whenever a sweep delivers something new.
final recentActivityProvider = FutureProvider<List<JobRun>>((ref) async {
  ref.watch(taskDeliveryProvider);
  final service = ref.watch(hermesCronServiceProvider);
  if (service == null) return const [];
  final jobs = await ref.watch(scheduledJobsProvider.future);

  final runs = <JobRun>[];
  for (final job in jobs) {
    for (final run in await service.readOutputs(job.id)) {
      runs.add((jobId: job.id, jobName: job.name, at: run.at, text: run.text));
    }
  }
  runs.sort((a, b) => b.at.compareTo(a.at));
  return runs;
});

/// Which job the detail pane shows. Null until the user picks one (or creates
/// one, which selects it).
final selectedJobIdProvider = NotifierProvider<SelectedJobId, String?>(
  SelectedJobId.new,
);

class SelectedJobId extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? id) => state = id;
}

/// The saved tasks, straight from Hermes's own store — the app keeps no second
/// list, so what you see here is exactly what will run.
///
/// Every action writes through the `hermes cron` CLI and then re-reads the store,
/// so the screen can't drift from the scheduler's idea of the world.
final scheduledJobsProvider =
    AsyncNotifierProvider<ScheduledJobsController, List<ScheduledJob>>(
      ScheduledJobsController.new,
    );

class ScheduledJobsController extends AsyncNotifier<List<ScheduledJob>> {
  @override
  Future<List<ScheduledJob>> build() => _load();

  Future<List<ScheduledJob>> _load() async {
    final service = ref.read(hermesCronServiceProvider);
    if (service == null) return const [];
    final raw = await service.readJobsJson();
    if (raw == null || raw.trim().isEmpty) return const [];
    return parseScheduledJobs(raw);
  }

  /// Save a new task and hand back what the dialog needs to follow up: an
  /// [error] to show, or the [id] of the job that was created so the screen can
  /// open it. On success [error] is null; [id] is null only when Hermes saved
  /// the job but we couldn't tell which of its jobs is the new one.
  ///
  /// The job runs in the Projects folder, so a task like "summarise my notes"
  /// can actually see them. Set [runNow] to fire it once straight away — a "try
  /// it now" that doesn't make the user hunt the task down afterwards.
  ///
  /// Pass [workdir] to run the task in a specific folder (a project's, so it can
  /// read that project's files) instead of the shared agent workspace; pass
  /// [projectId] to record which project it belongs to, so the project's rail
  /// can list it. The two go together — a project-scoped task supplies both.
  Future<({String? error, String? id})> create({
    required String name,
    required String prompt,
    required JobSchedule schedule,
    String? workdir,
    String? projectId,
    bool toTelegram = false,
    bool runNow = false,
  }) async {
    // A task fires with nobody there to pick a model. Unless Hermes already has
    // one, every run would fail with a raw "no model configured", so point it
    // at the selected grid now — and refuse to save a task that could only
    // ever fail, handing back a line that says what to fix instead.
    final unpointed = await ref
        .read(hermesGridLinkProvider)
        .ensureModelForSelectedGrid();
    if (unpointed != null) return (error: unpointed, id: null);

    // Nobody is there to answer for a task that fires at 8am, so what it's
    // allowed to do is settled here, before it can run at all — and it's what
    // the screen said it would be.
    await ref.read(taskPowerProvider.notifier).applyBeforeSaving();

    // Remember the ids that existed before, so we can spot the one Hermes just
    // added without needing it to hand back an id the CLI doesn't print.
    final before = {
      for (final job in state.value ?? const <ScheduledJob>[]) job.id,
    };
    final error = await _act(
      (service) => service.create(
        schedule: schedule.toSchedule(),
        prompt: prompt,
        name: name,
        workdir: workdir ?? ref.read(agentWorkspaceDirProvider).path,
        deliver: toTelegram ? kDeliverTelegram : kDeliverLocal,
      ),
    );
    if (error != null) return (error: error, id: null);

    final created = (state.value ?? const <ScheduledJob>[])
        .where((job) => !before.contains(job.id))
        .firstOrNull;
    // Tie the new task to its project so the project's rail shows only its own.
    if (created != null && projectId != null) {
      ref.read(projectTasksProvider.notifier).assign(created.id, projectId);
    }
    if (created != null && runNow) {
      // Best-effort: the task is saved either way, so a run that can't be
      // kicked off now isn't worth failing the whole create over.
      await this.runNow(created.id);
    }
    return (error: null, id: created?.id);
  }

  /// Let a task the scheduler has been skipping run on the model this computer
  /// uses now, and clear the skip it was showing.
  ///
  /// Hermes stops running a task whose model changed after it was created — the
  /// app changed it, by pointing Hermes at another grid or model. Re-creating the
  /// task is the only other way out and costs the user its results, so this is
  /// the one-tap path back for a task that's already stranded.
  Future<String?> useCurrentModel(String id) async {
    final service = ref.read(hermesCronServiceProvider);
    if (service == null) return _noAgent;
    final model = await ref.read(hermesGridLinkProvider).configuredModel();
    if (model == null) {
      return 'This computer has no AI model set for tasks yet. Pick a grid in '
          'Chat, then try again.';
    }
    // The one-tap fix must not arm the task on a model that can't run it: a
    // config left naming a CLI seat would otherwise hand the task the very
    // model whose runs come back as raw tool-call JSON (03/08).
    final refusal = hermesModelRefusal(model);
    if (refusal != null) return refusal;
    try {
      await service.followModel(model, onlyJobId: id);
    } on CronRearmException catch (error) {
      return "Couldn't switch this task to your current model: "
          '${error.message}';
    }
    state = AsyncData(await _load());
    return null;
  }

  Future<String?> pause(String id) => _act((s) => s.pause(id));

  Future<String?> resume(String id) => _act((s) => s.resume(id));

  Future<String?> runNow(String id) => _act((s) => s.runNow(id));

  Future<String?> remove(String id) async {
    final error = await _act((s) => s.remove(id));
    if (error != null) return error;
    // Drop the project link too, so a project's rail doesn't keep pointing at a
    // task that's gone.
    ref.read(projectTasksProvider.notifier).unassign(id);
    if (ref.read(selectedJobIdProvider) == id) {
      ref.read(selectedJobIdProvider.notifier).select(null);
    }
    return null;
  }

  /// Start the scheduler, then re-check — so the warning banner clears itself
  /// rather than leaving the user wondering whether it worked.
  Future<String?> startScheduler() async {
    final service = ref.read(hermesCronServiceProvider);
    if (service == null) return _noAgent;
    try {
      await service.startScheduler();
    } on HermesCronException catch (error) {
      return "Couldn't start the scheduler: ${error.message}";
    }
    ref.invalidate(schedulerRunningProvider);
    return null;
  }

  /// Run one write against the scheduler and re-read the store. Failures come
  /// back as a message instead of an exception: every caller is a button, and a
  /// button needs something to say.
  Future<String?> _act(Future<void> Function(HermesCronService) write) async {
    final service = ref.read(hermesCronServiceProvider);
    if (service == null) return _noAgent;
    try {
      await write(service);
    } on HermesCronException catch (error) {
      return error.message;
    }
    state = AsyncData(await _load());
    return null;
  }

  static const _noAgent =
      "This computer isn't set up to run tasks yet. Open the account menu ▸ "
      'This computer to finish setting it up.';
}
