import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/grid_paths.dart';
import '../../features/agent/logic/hermes_tool.dart';
import 'hermes_cron_rearm.dart';
import 'host_environment.dart';

/// The scheduler seam, or null when the agent isn't installed — there is nothing
/// to schedule *on* then, and the screen says so instead of failing later.
///
/// Lives beside the service rather than in the tasks feature: pointing Hermes at
/// a grid re-arms the saved tasks, so the agent feature needs this seam too.
final hermesCronServiceProvider = Provider<HermesCronService?>((ref) {
  final path = ref.watch(hermesPathProvider);
  return path == null ? null : HermesCronServiceImpl(path);
});

/// Raised when a `hermes cron` command fails, carrying the line the CLI printed
/// so the controller can humanize it instead of inventing a message.
class HermesCronException implements Exception {
  const HermesCronException(this.message);

  final String message;

  @override
  String toString() => 'HermesCronException: $message';
}

/// Keep the answer on this computer: Hermes writes it to a file and the app
/// delivers it into the task's chat — the one place a result is guaranteed to
/// reach the user, whether or not they ever connect a chat platform.
const String kDeliverLocal = 'local';

/// One finished run of a scheduled job: when it ran, and what it produced.
typedef CronOutput = ({DateTime at, String text});

/// When a run happened, read off the name Hermes gives its output file
/// (`2026-07-14_08-00-00.md`, in this computer's own time). Null when the name
/// isn't one — an unreadable file is skipped rather than dated "now", which would
/// shuffle it to the top of the results as if it had just happened.
DateTime? parseCronOutputTime(String fileName) {
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})\.md$',
  ).firstMatch(fileName);
  if (match == null) return null;
  final parts = [for (var i = 1; i <= 6; i++) int.parse(match.group(i)!)];
  return DateTime(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]);
}

/// The seam onto Hermes's own scheduler (`hermes cron`).
///
/// Hermes already schedules and runs the jobs — the app doesn't reimplement any
/// of that. It writes jobs through the CLI, reads them back from Hermes's store,
/// and checks that the thing which fires them (Hermes's gateway) is alive.
abstract interface class HermesCronService {
  /// The raw contents of Hermes's job store, or null when it has none yet.
  Future<String?> readJobsJson();

  /// What the job's runs produced, oldest first. Hermes writes one file per run
  /// under `~/.hermes/cron/output/<job>/`; this is the only record of a result
  /// delivered "local", so it's where the app collects them from. Empty when the
  /// job has never run.
  Future<List<CronOutput>> readOutputs(String jobId);

  /// Create a job. [schedule] is a cron expression; [workdir] is the folder the
  /// job runs in (Projects), so a task can read the user's files. The answer
  /// always lands in the app ([kDeliverLocal]).
  Future<void> create({
    required String schedule,
    required String prompt,
    required String name,
    String? workdir,
  });

  /// Pin [jobId] to [model] — what it answers with from now on, whatever the
  /// computer's own model becomes.
  ///
  /// The app pins every task it creates: an unpinned job is skipped unrun the
  /// first time the user changes model in Chat (Hermes's drift guard, #44585),
  /// and the model a task runs on is a choice worth keeping still. Pass
  /// [clearError] when the pin is the fix for the error the task is showing.
  ///
  /// Throws [CronRearmException] when Hermes's store refuses the write.
  Future<void> pinModel(String jobId, String model, {bool clearError = false});

  Future<void> pause(String id);
  Future<void> resume(String id);
  Future<void> remove(String id);

  /// Queue [id] to run on the scheduler's next tick (seconds away), so the user
  /// can try a task without waiting for its time to come round.
  Future<void> runNow(String id);

  /// Let the saved tasks run on [model] — the model this computer answers with
  /// now — and hand back the ids that needed it.
  ///
  /// Hermes skips a task whose global model changed since it was created and
  /// spends nothing, leaving a raw "Skipped to prevent unintended spend"
  /// (#44585). The app is what changed that model — it points Hermes at the grid
  /// the user picked — so without this every saved task dies the moment the user
  /// switches model, and stays dead. Pass [onlyJobId] to re-arm the one task the
  /// user asked about.
  ///
  /// Throws [CronRearmException] when the change couldn't be applied.
  Future<List<String>> followModel(String model, {String? onlyJobId});

  /// Whether the scheduler that fires jobs is alive. Jobs are stored either way;
  /// without it they simply never run — so the UI has to be able to say so.
  Future<bool> schedulerRunning();

  /// Start the scheduler (Hermes's background gateway service).
  Future<void> startScheduler();
}

/// Real implementation: spawns the `hermes` binary and reads its cron store.
class HermesCronServiceImpl implements HermesCronService {
  HermesCronServiceImpl(this.binPath, {String? home})
    : _home = home ?? GridPaths.userHome;

  /// Absolute path to the hermes binary (it isn't on a GUI app's default PATH).
  final String binPath;
  final String _home;

  /// How fresh the scheduler's heartbeat must be to count as alive. Hermes
  /// touches it every ~10s; a minute of slack absorbs a busy machine without
  /// calling a dead scheduler alive.
  static const _heartbeatMaxAge = Duration(seconds: 60);

  Directory get _cronDir => Directory('$_home/.hermes/cron');

  @override
  Future<String?> readJobsJson() async {
    final file = File('${_cronDir.path}/jobs.json');
    if (!file.existsSync()) return null;
    return file.readAsString();
  }

  @override
  Future<void> create({
    required String schedule,
    required String prompt,
    required String name,
    String? workdir,
  }) => _run([
    'cron',
    'create',
    schedule,
    prompt,
    '--name',
    name,
    // The answer comes back into the app, always: it's where the user asked for
    // the task, and it's the only destination that needs nothing set up first.
    '--deliver',
    kDeliverLocal,
    if (workdir != null) ...['--workdir', workdir],
  ]);

  @override
  Future<void> pinModel(
    String jobId,
    String model, {
    bool clearError = false,
  }) => HermesCronRearm(
    binPath: binPath,
    home: _home,
  ).pin(model, [jobId], clearError: clearError);

  @override
  Future<List<CronOutput>> readOutputs(String jobId) async {
    final dir = Directory('${_cronDir.path}/output/$jobId');
    if (!dir.existsSync()) return const [];

    final runs = <CronOutput>[];
    for (final entry in dir.listSync()) {
      if (entry is! File || !entry.path.endsWith('.md')) continue;
      final at = parseCronOutputTime(entry.uri.pathSegments.last);
      if (at == null) continue;
      final text = (await entry.readAsString()).trim();
      if (text.isEmpty) continue;
      runs.add((at: at, text: text));
    }
    runs.sort((a, b) => a.at.compareTo(b.at));
    return runs;
  }

  @override
  Future<List<String>> followModel(String model, {String? onlyJobId}) async {
    final raw = await readJobsJson();
    if (raw == null) return const [];
    return HermesCronRearm(
      binPath: binPath,
      home: _home,
    ).apply(raw, model, onlyJobId: onlyJobId);
  }

  @override
  Future<void> pause(String id) => _run(['cron', 'pause', id]);

  @override
  Future<void> resume(String id) => _run(['cron', 'resume', id]);

  @override
  Future<void> remove(String id) => _run(['cron', 'remove', id]);

  @override
  Future<void> runNow(String id) => _run(['cron', 'run', id]);

  @override
  Future<bool> schedulerRunning() async {
    // The heartbeat file, not `hermes gateway status`: it's a single stat
    // instead of a process spawn, so the screen can check it on every refresh.
    final beat = File('${_cronDir.path}/ticker_heartbeat');
    if (!beat.existsSync()) return false;
    final seconds = double.tryParse((await beat.readAsString()).trim());
    if (seconds == null) return false;
    final last = DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round());
    return DateTime.now().difference(last) < _heartbeatMaxAge;
  }

  @override
  Future<void> startScheduler() => _run(['gateway', 'start']);

  Future<void> _run(List<String> args) async {
    final result = await Process.run(
      binPath,
      args,
      environment: HostEnvironment.hermesEnvironment(),
    );
    if (result.exitCode == 0) return;
    final stderr = (result.stderr as String).trim();
    final stdout = (result.stdout as String).trim();
    throw HermesCronException(stderr.isNotEmpty ? stderr : stdout);
  }
}
