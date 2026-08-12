import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/hermes_cron_rearm.dart';
import '../../../infrastructure/cli/hermes_cron_service.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../agents/logic/agent_providers.dart';
import '../../agents/logic/adapters/hermes_grid_link.dart';
import '../../network/logic/node_display.dart';
import '../../projects/logic/project_tasks_store.dart';
import '../../../shared/copy/setup_hints.dart';
import 'job_schedule.dart';
import 'scheduled_job.dart';
import 'task_inbox_store.dart';
import 'task_model_fallback.dart';
import 'task_power_controller.dart';

/// Whether the thing that actually fires jobs is alive. Jobs are saved either
/// way, so this is what lets the screen tell the truth: "saved, but nothing will
/// run until the scheduler is on".
final schedulerRunningProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(hermesCronServiceProvider);
  return service != null && await service.schedulerRunning();
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
  /// The store exactly as it was last read, so a re-read that changed nothing
  /// leaves the screen alone instead of rebuilding it on every sweep.
  String? _lastRaw;

  @override
  Future<List<ScheduledJob>> build() => _load();

  Future<List<ScheduledJob>> _load() async {
    final service = ref.read(hermesCronServiceProvider);
    if (service == null) return const [];
    return _parse(await service.readJobsJson());
  }

  /// Re-read the store because something *outside* the app may have changed it.
  ///
  /// The app isn't the only thing that writes tasks: the assistant creates them
  /// mid-conversation when you ask it to, and so does `hermes cron` in a
  /// terminal. Loading once and only re-reading after the app's own writes meant
  /// a task the assistant had just confirmed creating was missing from this
  /// screen until the next launch — and, worse, its results were never delivered
  /// into a chat, because the sweep walks this same list.
  Future<void> refresh() async {
    final service = ref.read(hermesCronServiceProvider);
    // Mid-load: the build in flight is about to publish a fresher read than
    // this one, and racing it would only overwrite it with the same thing.
    if (service == null || state.isLoading) return;
    final raw = await service.readJobsJson();
    if (raw == _lastRaw) return;
    state = AsyncData(_parse(raw));
  }

  List<ScheduledJob> _parse(String? raw) {
    _lastRaw = raw;
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
  ///
  /// [model] is the one the user picked in the dialog, and the task is **pinned**
  /// to it: it keeps answering with that model when the chat moves to another,
  /// instead of being skipped unrun by Hermes's drift guard.
  Future<({String? error, String? id})> create({
    required String name,
    required String prompt,
    required JobSchedule schedule,
    required String model,
    String? workdir,
    String? projectId,
    bool runNow = false,
  }) async {
    // The model has to be one Hermes can actually answer with — the picker only
    // offers those, but this is the door every caller comes through.
    final refusal = hermesModelRefusal(model);
    if (refusal != null) return (error: refusal, id: null);
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
      ),
    );
    if (error != null) return (error: error, id: null);

    final created = (state.value ?? const <ScheduledJob>[])
        .where((job) => !before.contains(job.id))
        .firstOrNull;
    // Pin it to the model the user picked. Only possible once the job exists
    // (`cron create` has no --model), so it's a second write — and one worth
    // reporting: a task that silently kept following the chat's model is the
    // drift skip all over again.
    if (created != null) {
      final pinned = await _pin(created.id, model);
      if (pinned != null) return (error: pinned, id: created.id);
    }
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

  /// Save changes to a task that already exists, keeping its results and its
  /// place in the schedule.
  ///
  /// Recreating it was the only way to fix a typo before this, and it cost the
  /// user every result the task had produced. Only what the form asks for moves;
  /// the folder it runs in and what it's allowed to do stay as they were.
  ///
  /// The model is a second write, as it is on create — `cron edit` has no
  /// `--model` — and only when the user actually moved it, so an edit to the
  /// wording doesn't re-pin (and silently clear) a task that is failing for a
  /// reason nobody has looked at yet.
  Future<String?> edit({
    required String id,
    required String name,
    required String prompt,
    required JobSchedule schedule,
    required String model,
  }) async {
    final refusal = hermesModelRefusal(model);
    if (refusal != null) return refusal;
    // Read before the write: `_act` re-reads the store, and the answer to "did
    // the user change the model?" is only in the job as it stands now.
    final moved = _jobById(id)?.model != model;

    final error = await _act(
      (service) => service.edit(
        id: id,
        schedule: schedule.toSchedule(),
        prompt: prompt,
        name: name,
      ),
    );
    if (error != null) return error;
    if (!moved) return null;
    // Picking a model *is* the fix for a task the scheduler was skipping, so the
    // stale skip goes with it — the same reasoning as `useCurrentModel`.
    return _pin(id, model, clearError: true);
  }

  /// Let a task the scheduler has been skipping run on the model this computer
  /// uses now, and clear the skip it was showing.
  ///
  /// Hermes stops running a task whose model changed after it was created — the
  /// app changed it, by pointing Hermes at another grid or model. Re-creating the
  /// task is the only other way out and costs the user its results, so this is
  /// the one-tap path back for a task that's already stranded.
  ///
  /// Two shapes of task reach here: one the app pinned (re-pin it) and one from
  /// before it did (re-arm it, which re-snapshots and leaves it unpinned). A
  /// re-arm silently skips a pinned job, so telling them apart is what keeps the
  /// button from reporting a success it didn't have.
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
    // model whose runs come back as the tool call typed out (03/08).
    final refusal = hermesModelRefusal(model);
    if (refusal != null) return refusal;
    if (_jobById(id)?.model != null) return _pin(id, model, clearError: true);
    try {
      await service.followModel(model, onlyJobId: id);
    } on CronRearmException catch (error) {
      return "Couldn't switch this task to your current model: "
          '${error.message}';
    }
    state = AsyncData(await _load());
    return null;
  }

  /// Move every task whose pinned model has stopped working onto the grid's
  /// router (`auto`), and hand back the ids moved.
  ///
  /// A task fires with nobody watching, so a model that has gone quiet doesn't
  /// produce an error someone reads — it produces months of nothing. [served] is
  /// what the grid lists right now; empty reads as "don't know", so an unloaded
  /// list never re-points anything (see [autoFallbackTargets]).
  ///
  /// The swap is logged with its evidence: the app is overriding a choice the
  /// user made, and a silent override is indistinguishable from a bug.
  Future<List<String>> fallbackToAuto(Set<String> served) async {
    final service = ref.read(hermesCronServiceProvider);
    if (service == null) return const [];
    final jobs = state.value ?? const <ScheduledJob>[];
    final targets = autoFallbackTargets(jobs, served);
    if (targets.isEmpty) return const [];

    final log = ref.read(appLogProvider);
    final moved = <String>[];
    for (final job in jobs.where((job) => targets.contains(job.id))) {
      try {
        await service.pinModel(job.id, kAutoModelId, clearError: true);
        moved.add(job.id);
        log.info(
          'tasks',
          'switched to auto — ${autoFallbackReason(job, served)}',
        );
      } on CronRearmException catch (error) {
        log.failure(
          'tasks',
          "couldn't switch \"${job.name}\" to auto: ${error.message}",
        );
      }
    }
    if (moved.isNotEmpty) state = AsyncData(await _load());
    return List.unmodifiable(moved);
  }

  /// Pin [id] to [model] as a line to show rather than an exception — every
  /// caller is a button or a sweep, and neither can catch.
  Future<String?> _pin(
    String id,
    String model, {
    bool clearError = false,
  }) async {
    final service = ref.read(hermesCronServiceProvider);
    if (service == null) return _noAgent;
    try {
      await service.pinModel(id, model, clearError: clearError);
    } on CronRearmException catch (error) {
      return "Couldn't set the model this task runs on: ${error.message}";
    }
    state = AsyncData(await _load());
    return null;
  }

  ScheduledJob? _jobById(String id) => (state.value ?? const <ScheduledJob>[])
      .where((job) => job.id == id)
      .firstOrNull;

  Future<String?> pause(String id) => _act((s) => s.pause(id));

  Future<String?> resume(String id) => _act((s) => s.resume(id));

  Future<String?> runNow(String id) => _act((s) => s.runNow(id));

  Future<String?> remove(String id) async {
    final error = await _act((s) => s.remove(id));
    if (error != null) return error;
    // Drop the project link too, so a project's rail doesn't keep pointing at a
    // task that's gone — and the headline of its last result, which would
    // otherwise outlive the task in the store forever.
    ref.read(projectTasksProvider.notifier).unassign(id);
    ref.read(taskInboxProvider.notifier).forget(id);
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

  static final _noAgent = notSetUpToMessage('run tasks');
}
