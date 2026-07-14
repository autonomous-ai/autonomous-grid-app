import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/hermes_cron_service.dart';
import '../../agent/logic/agent_providers.dart';
import '../../agent/logic/hermes_tool.dart';
import 'job_schedule.dart';
import 'scheduled_job.dart';

/// The scheduler seam, or null when the agent isn't installed — there is nothing
/// to schedule *on* then, and the screen says so instead of failing later.
final hermesCronServiceProvider = Provider<HermesCronService?>((ref) {
  final path = ref.watch(hermesPathProvider);
  return path == null ? null : HermesCronServiceImpl(path);
});

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
  @override
  Future<List<ScheduledJob>> build() => _load();

  Future<List<ScheduledJob>> _load() async {
    final service = ref.read(hermesCronServiceProvider);
    if (service == null) return const [];
    final raw = await service.readJobsJson();
    if (raw == null || raw.trim().isEmpty) return const [];
    return parseScheduledJobs(raw);
  }

  /// Save a new task. Returns null on success, else a line to show the user.
  ///
  /// The job runs in the Projects folder, so a task like "summarise my notes"
  /// can actually see them.
  Future<String?> create({
    required String name,
    required String prompt,
    required JobSchedule schedule,
  }) => _act(
    (service) => service.create(
      schedule: schedule.toCron(),
      prompt: prompt,
      name: name,
      workdir: ref.read(agentWorkspaceDirProvider).path,
    ),
  );

  Future<String?> pause(String id) => _act((s) => s.pause(id));

  Future<String?> resume(String id) => _act((s) => s.resume(id));

  Future<String?> runNow(String id) => _act((s) => s.runNow(id));

  Future<String?> remove(String id) async {
    final error = await _act((s) => s.remove(id));
    if (error == null && ref.read(selectedJobIdProvider) == id) {
      ref.read(selectedJobIdProvider.notifier).select(null);
    }
    return error;
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
