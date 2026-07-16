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
    this.nextRunAt,
    this.lastRunAt,
    this.lastStatus,
    this.lastError,
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

  final DateTime? nextRunAt;
  final DateTime? lastRunAt;

  /// How the last run ended, as Hermes reported it ('ok', 'error', …).
  final String? lastStatus;
  final String? lastError;

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
    nextRunAt: _time(raw['next_run_at']),
    lastRunAt: _time(raw['last_run_at']),
    lastStatus: _stringOrNull(raw['last_status']),
    lastError: _stringOrNull(raw['last_error']),
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
