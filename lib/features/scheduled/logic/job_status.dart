import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import 'cron_error.dart';
import 'job_schedule.dart';
import 'scheduled_job.dart';

/// A task's state as one thing to show: a word, a colour, and the dot colour that
/// goes with it. One source of truth so the list row and the detail pane can't
/// disagree about what "failed" or "paused" looks like.
enum JobStatus {
  /// On schedule and the last run (if any) was fine.
  running,

  /// On schedule, but the last run ended in an error — still live, still worth
  /// a glance, so warn rather than fault.
  lastRunFailed,

  /// Still enabled, but the scheduler is skipping every run and won't stop until
  /// the user acts (today: the model drifted from what the task was created on).
  /// A "failed last run" reads as bad luck that might pass; this won't pass on
  /// its own, so it gets its own, blunter label.
  blocked,

  /// The user paused it: it stays in the list but won't run.
  paused,
}

/// Which state [job] is in. Order matters: a user's pause wins over anything
/// (a paused task isn't "failing"); a scheduler block wins over a plain failed
/// run (it's the reason the run failed, and it won't clear itself).
JobStatus jobStatusOf(ScheduledJob job) {
  if (!job.enabled) return JobStatus.paused;
  if (job.failed && isModelDriftSkip(job.lastError!)) return JobStatus.blocked;
  if (job.failed) return JobStatus.lastRunFailed;
  return JobStatus.running;
}

/// The short label on the status pill, in the user's language.
String jobStatusLabel(JobStatus status) => switch (status) {
  JobStatus.running => 'On',
  JobStatus.lastRunFailed => 'Last run failed',
  JobStatus.blocked => "Won't run",
  JobStatus.paused => 'Paused',
};

/// The colour for the pill text and the row's status dot. Semantic, not the
/// accent: green for healthy, warn for a failed run or a block, muted for paused.
Color jobStatusColor(JobStatus status) => switch (status) {
  JobStatus.running => AppPalette.online,
  JobStatus.lastRunFailed => AppPalette.warn,
  JobStatus.blocked => AppPalette.warn,
  JobStatus.paused => AppPalette.offline,
};

/// A short, human line for when a task last ran and how it went — "Ran 09:00
/// today", "Failed yesterday". Null when it has never run, so the caller can
/// omit the line entirely rather than print "never".
String? jobLastRunLine(ScheduledJob job, DateTime now) {
  final at = job.lastRunAt;
  if (at == null) return null;
  final verb = job.failed ? 'Failed' : 'Ran';
  return '$verb ${_relativePast(at, now)}';
}

/// A short line for when the task fires next — "Runs in 3h", "Runs tomorrow
/// 09:00". Null when it's paused or has no next time, so the row shows nothing
/// rather than a misleading "soon".
String? jobNextRunLine(ScheduledJob job, DateTime now) {
  if (!job.enabled) return null;
  final at = job.nextRunAt;
  if (at == null) return null;
  return 'Runs ${_relativeFuture(at, now)}';
}

/// "in 3h", "in 12m", "tomorrow 09:00", "on 14/07 at 09:00" — how far ahead
/// [at] is, from [now]. Near times read as a countdown (what the user cares
/// about at a glance); far ones fall back to the calendar.
String _relativeFuture(DateTime at, DateTime now) {
  final d = at.difference(now);
  if (d.inMinutes <= 0) return 'any moment now';
  if (d.inMinutes < 60) return 'in ${d.inMinutes}m';
  if (d.inHours < 24 && _isSameDay(at, now)) return 'in ${d.inHours}h';
  if (_isSameDay(at, now.add(const Duration(days: 1)))) {
    return 'tomorrow ${_time(at)}';
  }
  return 'on ${jobTimeLabel(at)}';
}

/// "just now", "5m ago", "today 09:00", "yesterday 09:00", "on 14/07 at 09:00".
String _relativePast(DateTime at, DateTime now) {
  final d = now.difference(at);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (_isSameDay(at, now)) return 'today ${_time(at)}';
  if (_isSameDay(at, now.subtract(const Duration(days: 1)))) {
    return 'yesterday ${_time(at)}';
  }
  return 'on ${jobTimeLabel(at)}';
}

bool _isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _time(DateTime t) {
  final local = t.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}
