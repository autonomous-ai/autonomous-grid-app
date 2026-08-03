import 'dart:convert';
import 'dart:io';

import '../../features/scheduled/logic/cron_error.dart';
import 'host_environment.dart';

/// One task to re-arm, with whether the error it's showing should go with it.
///
/// [clearError] is only ever true for the drift skip itself: once the task
/// follows the current model that message is stale, and a task that will run
/// must not keep saying "won't run". Any other failure is real history and stays.
typedef CronRearmTarget = ({String id, bool clearError});

/// Shown when Hermes is installed in a layout this can't reach into — the user
/// gets a next step instead of a task that silently stays blocked.
const String kCronRearmUnavailable =
    "Couldn't reach the scheduler's settings on this computer. Delete the task "
    'and create it again to run it on the current model.';

/// The tasks that need re-arming so the scheduler runs them on [model].
///
/// Hermes snapshots the model an unpinned job was created on and fail-closes the
/// run when the global model has moved on (#44585). This finds the jobs that
/// snapshot has stranded: unpinned (a pin is somebody's deliberate choice, never
/// overridden here) and snapshotted on something other than [model].
///
/// Pass [onlyJobId] for a task the user asked about by name — that one is
/// re-armed even when its snapshot already matches, so a stale "won't run" error
/// clears instead of sitting on a task that would in fact run.
///
/// Pure, and lenient like the store's other reader: a job entry Hermes has
/// reshaped is skipped rather than taking the whole re-arm down with it.
List<CronRearmTarget> cronRearmTargets(
  String rawJobsJson, {
  required String model,
  String? onlyJobId,
}) {
  if (model.trim().isEmpty) return const [];
  final jobs = _jobsIn(rawJobsJson);

  final targets = <CronRearmTarget>[];
  for (final raw in jobs) {
    if (raw is! Map<String, dynamic>) continue;
    final id = _text(raw['id']);
    if (id == null) continue;
    if (onlyJobId != null && id != onlyJobId) continue;
    // A pinned job answers with the model somebody chose for it; the guard never
    // fires for it and this must not quietly re-route it.
    if (_text(raw['model']) != null) continue;
    final snapshot = _text(raw['model_snapshot']);
    final armed =
        snapshot == null ||
        snapshot.toLowerCase() == model.trim().toLowerCase();
    if (armed && onlyJobId == null) continue;
    final lastError = _text(raw['last_error']);
    targets.add((
      id: id,
      clearError: lastError != null && isModelDriftSkip(lastError),
    ));
  }
  return List.unmodifiable(targets);
}

/// argv for Hermes's own interpreter that re-arms every target in one go.
///
/// The targets travel as JSON on the command line rather than being re-derived
/// on the other side: what to touch is decided here, in tested Dart, and the
/// program below only applies it.
List<String> cronRearmArgs({
  required String model,
  required List<CronRearmTarget> targets,
}) => [
  '-c',
  kCronRearmProgram,
  model.trim(),
  jsonEncode([
    for (final target in targets)
      {'id': target.id, 'clear_error': target.clearError},
  ]),
];

/// argv that pins [jobIds] to [model] and leaves them pinned.
///
/// The counterpart to [cronRearmArgs]: that one ends unpinned (the job goes back
/// to following the computer's model), this one is how a task the user chose a
/// model for keeps it. Pass [clearError] when the pin is the fix for the error
/// showing on the task — a task that will now run must not keep saying it won't.
List<String> cronPinArgs({
  required String model,
  required List<String> jobIds,
  bool clearError = false,
}) => [
  '-c',
  kCronPinProgram,
  model.trim(),
  jsonEncode(jobIds),
  clearError ? '1' : '0',
];

/// Pin a job to one model through Hermes's own job store.
///
/// `hermes cron create` has no `--model` flag (v0.19.0), so a task can only be
/// pinned after it exists — which is also what makes the pin worth doing: an
/// unpinned job is skipped, unrun, the first time the computer's model changes
/// (#44585), and the user picked a model for this one precisely so it wouldn't
/// follow the chat around.
const String kCronPinProgram = '''
import json, sys
from cron.jobs import update_job

model, job_ids, clear = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3] == "1"
for job_id in job_ids:
    updates = {"model": model}
    if clear:
        updates["last_error"] = None
        updates["last_status"] = None
    update_job(job_id, updates)
''';

/// Re-point a job at the current model through Hermes's own job store.
///
/// `hermes cron edit` has no `--model`/`--provider` flag (v0.19.0), so the CLI
/// cannot re-snapshot a job — Hermes only refreshes the snapshot when an update
/// changes an inference field. Hence the two writes: pin to the model this
/// computer uses now, then unpin. The unpin is what re-snapshots, and the job
/// goes back to following global config instead of being frozen on one model.
///
/// The order matters: the pin lands first so a tick firing between the two
/// writes runs on the intended model rather than on a stale snapshot.
///
/// TODO(BE): ask Hermes for `cron create/edit --model/--provider`. Reaching into
/// `cron.jobs` works but rides on an internal module; a flag would make this a
/// one-line CLI call.
const String kCronRearmProgram = '''
import json, sys
from cron.jobs import update_job

model, targets = sys.argv[1], json.loads(sys.argv[2])
for target in targets:
    job_id = target["id"]
    update_job(job_id, {"model": model})
    updates = {"model": None}
    if target.get("clear_error"):
        updates["last_error"] = None
        updates["last_status"] = None
    update_job(job_id, updates)
''';

/// The one line worth showing from a failed re-arm.
///
/// Python answers a rejected write with a whole traceback whose last line is the
/// only part that names the failure; showing the lot would bury it. Falls back to
/// a plain sentence when the process failed without saying anything, so the
/// caller always has something to put in front of the user.
String cronRearmFailure(String stderr, String stdout) {
  final text = stderr.trim().isNotEmpty ? stderr : stdout;
  final lines = text
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty);
  return lines.isEmpty ? 'the scheduler rejected the change' : lines.last;
}

/// Applies a re-arm inside Hermes's own store, by running Hermes's `cron.jobs`
/// module on Hermes's own interpreter.
class HermesCronRearm {
  const HermesCronRearm({required this.binPath, required this.home});

  /// Absolute path to the hermes binary — its venv's interpreter sits beside it.
  final String binPath;

  /// The user's home, so a test can point the whole thing at a temp `.hermes`.
  final String home;

  /// Re-arm what [rawJobsJson] says is stranded, and hand back the ids touched.
  ///
  /// Throws [CronRearmException] when Hermes's own store refuses the change, so
  /// the caller can show what it said instead of reporting a silent success.
  Future<List<String>> apply(
    String rawJobsJson,
    String model, {
    String? onlyJobId,
  }) async {
    final targets = cronRearmTargets(
      rawJobsJson,
      model: model,
      onlyJobId: onlyJobId,
    );
    if (targets.isEmpty) return const [];
    await _write(cronRearmArgs(model: model, targets: targets));
    return [for (final target in targets) target.id];
  }

  /// Pin [jobIds] to [model] so they answer with it whatever the computer's own
  /// model becomes. Throws [CronRearmException] like [apply] when the store
  /// refuses the write.
  Future<void> pin(
    String model,
    List<String> jobIds, {
    bool clearError = false,
  }) async {
    if (jobIds.isEmpty || model.trim().isEmpty) return;
    await _write(
      cronPinArgs(model: model, jobIds: jobIds, clearError: clearError),
    );
  }

  /// Run one of the programs above on Hermes's own interpreter, against Hermes's
  /// own store.
  Future<void> _write(List<String> args) async {
    final python = _interpreter();
    if (python == null) throw const CronRearmException(kCronRearmUnavailable);

    final result = await Process.run(
      python,
      args,
      environment: {
        ...HostEnvironment.hermesEnvironment(),
        // Honour the home this was built with, so a test never writes to the
        // real `~/.hermes`.
        'HERMES_HOME': '$home/.hermes',
      },
    );
    if (result.exitCode != 0) {
      throw CronRearmException(
        cronRearmFailure(result.stderr as String, result.stdout as String),
      );
    }
  }

  /// The interpreter Hermes itself runs on: its venv's `python`, beside the
  /// binary. Null when the install isn't that layout — the caller then says so
  /// rather than spawning something that isn't there.
  String? _interpreter() {
    try {
      final binDir = File(File(binPath).resolveSymbolicLinksSync()).parent.path;
      for (final name in const ['python', 'python.exe', 'python3']) {
        final candidate = File('$binDir/$name');
        if (candidate.existsSync()) return candidate.path;
      }
      return null;
    } on FileSystemException {
      return null;
    }
  }
}

/// Raised when a re-arm couldn't be applied, carrying the line to show.
class CronRearmException implements Exception {
  const CronRearmException(this.message);

  final String message;

  @override
  String toString() => 'CronRearmException: $message';
}

List<Object?> _jobsIn(String rawJson) {
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map<String, dynamic>) return const [];
    final jobs = decoded['jobs'];
    return jobs is List ? jobs : const [];
  } on FormatException {
    return const [];
  }
}

String? _text(Object? raw) {
  if (raw is! String) return null;
  final text = raw.trim();
  return text.isEmpty ? null : text;
}
