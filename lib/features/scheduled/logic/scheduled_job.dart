import 'dart:convert';

/// A task the assistant runs on its own, on a schedule.
///
/// This is Hermes's own cron job, read back from its store (`~/.hermes/cron/
/// jobs.json`) — the app doesn't keep a second list, so what the screen shows is
/// exactly what the scheduler will run.
class ScheduledJob {
  const ScheduledJob({
    required this.id,
    required this.name,
    required this.prompt,
    required this.cron,
    required this.enabled,
    this.model,
    this.nextRunAt,
    this.lastRunAt,
    this.lastStatus,
    this.lastError,
    this.deliver,
    this.script,
  });

  final String id;

  /// The human name, falling back to the prompt when a job was created without
  /// one — a row in the list must never be blank.
  final String name;
  final String prompt;

  /// The cron expression the scheduler fires on.
  final String cron;

  /// False when the user paused it: it stays in the list but doesn't run.
  final bool enabled;

  /// The model this task is **pinned** to — what it will answer with whatever
  /// the assistant is set to elsewhere. Null for a job that follows whatever
  /// model the computer is on (Hermes's own default, and how tasks made before
  /// the app pinned them still behave).
  ///
  /// Pinning is what stops Hermes's drift guard skipping a task the moment the
  /// user changes model in Chat (#44585), so every task the app creates carries
  /// one.
  final String? model;

  final DateTime? nextRunAt;
  final DateTime? lastRunAt;

  /// How the last run ended, as Hermes reported it ('ok', 'error', …).
  final String? lastStatus;
  final String? lastError;

  /// Where the answer goes, as it sits in Hermes's store — read back rather
  /// than remembered app-side, so a task's destination survives a reinstall and
  /// is the same one whether the app or an agent in a terminal created it.
  /// Null on every job made before destinations existed, which reads as the
  /// task's own chat (see `parseTaskDeliver`).
  final String? deliver;

  /// The script the scheduler runs instead of asking its own agent — set when
  /// the task is answered by Claude Code or Codex (see `TaskRunner`).
  final String? script;

  bool get failed => lastError != null && lastError!.isNotEmpty;
}

/// Reads Hermes's `jobs.json`. Lenient by design: a field Hermes adds or renames
/// must not blank the whole screen, so anything unreadable is skipped and the
/// rest still shows.
List<ScheduledJob> parseScheduledJobs(String rawJson) {
  final decoded = jsonDecode(rawJson);
  if (decoded is! Map<String, dynamic>) return const [];
  final jobs = decoded['jobs'];
  if (jobs is! List) return const [];

  final parsed = <ScheduledJob>[];
  for (final raw in jobs) {
    if (raw is! Map<String, dynamic>) continue;
    final job = _job(raw);
    if (job != null) parsed.add(job);
  }
  return parsed;
}

ScheduledJob? _job(Map<String, dynamic> raw) {
  final id = raw['id'];
  if (id is! String || id.isEmpty) return null;

  final prompt = _string(raw['prompt']);
  final name = _string(raw['name']);
  // A cron job carries an `expr`; an interval one (`every 30m`) carries only
  // `minutes` + a `display` string, so fall through to that rather than reading
  // an empty schedule and mislabelling the row.
  final schedule = raw['schedule'];
  final cron = _firstNonEmpty([
    if (schedule is Map<String, dynamic>) ...[
      _string(schedule['expr']),
      _string(schedule['display']),
    ],
    _string(raw['schedule_display']),
  ]);

  return ScheduledJob(
    id: id,
    name: name.isNotEmpty ? name : (prompt.isNotEmpty ? prompt : 'Task $id'),
    prompt: prompt,
    cron: cron,
    enabled: raw['enabled'] != false,
    model: _stringOrNull(raw['model']),
    nextRunAt: _time(raw['next_run_at']),
    lastRunAt: _time(raw['last_run_at']),
    lastStatus: _stringOrNull(raw['last_status']),
    lastError: _stringOrNull(raw['last_error']),
    deliver: _stringOrNull(raw['deliver']),
    script: _stringOrNull(raw['script']),
  );
}

String _string(Object? raw) => raw is String ? raw : '';

/// The first non-blank string in [candidates], or '' when they're all empty —
/// so a job's schedule reads from whichever field Hermes actually filled.
String _firstNonEmpty(List<String> candidates) =>
    candidates.firstWhere((s) => s.isNotEmpty, orElse: () => '');

String? _stringOrNull(Object? raw) =>
    raw is String && raw.isNotEmpty ? raw : null;

DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toLocal() : null;
