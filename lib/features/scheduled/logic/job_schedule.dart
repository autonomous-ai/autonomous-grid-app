/// How often a scheduled task runs. Three cadences cover what people actually
/// ask for ("every morning", "every weekday", "every Friday") without making
/// them learn cron.
enum JobCadence {
  everyDay('Every day'),
  weekdays('Every weekday'),
  weekly('Once a week');

  const JobCadence(this.label);

  final String label;
}

/// When a task runs, in the terms the app asks the user for: a cadence, a time of
/// day, and — for a weekly task — which day.
///
/// Hermes stores a cron expression, so this is the one place that translates
/// between the two. Everything else in the feature works in these terms.
class JobSchedule {
  const JobSchedule({
    required this.cadence,
    required this.hour,
    required this.minute,
    this.weekday = DateTime.monday,
  });

  final JobCadence cadence;

  /// 0–23, local time — the same clock the user sets it on, since Hermes's
  /// scheduler runs on this computer.
  final int hour;
  final int minute;

  /// `DateTime.monday`…`DateTime.sunday`. Only used by [JobCadence.weekly].
  final int weekday;

  /// The cron expression Hermes schedules on (`minute hour * * weekday`).
  String toCron() {
    final days = switch (cadence) {
      JobCadence.everyDay => '*',
      JobCadence.weekdays => '1-5',
      JobCadence.weekly => '${_cronWeekday(weekday)}',
    };
    return '$minute $hour * * $days';
  }

  /// A line a person can read: "Every weekday at 08:00".
  String describe() {
    final time = '${_two(hour)}:${_two(minute)}';
    return switch (cadence) {
      JobCadence.everyDay => 'Every day at $time',
      JobCadence.weekdays => 'Every weekday at $time',
      JobCadence.weekly => 'Every ${_weekdayName(weekday)} at $time',
    };
  }
}

/// Reads one of *our* cron expressions back into a [JobSchedule], or null when it
/// isn't one (a job written by hand in Hermes, say). Callers then fall back to
/// showing the raw expression rather than mislabelling it.
JobSchedule? parseJobCron(String expression) {
  final parts = expression.trim().split(RegExp(r'\s+'));
  if (parts.length != 5) return null;
  final minute = int.tryParse(parts[0]);
  final hour = int.tryParse(parts[1]);
  if (minute == null || hour == null) return null;
  if (minute < 0 || minute > 59 || hour < 0 || hour > 23) return null;
  if (parts[2] != '*' || parts[3] != '*') return null;

  final days = parts[4];
  if (days == '*') {
    return JobSchedule(
      cadence: JobCadence.everyDay,
      hour: hour,
      minute: minute,
    );
  }
  if (days == '1-5') {
    return JobSchedule(
      cadence: JobCadence.weekdays,
      hour: hour,
      minute: minute,
    );
  }
  final cronDay = int.tryParse(days);
  if (cronDay == null || cronDay < 0 || cronDay > 6) return null;
  return JobSchedule(
    cadence: JobCadence.weekly,
    hour: hour,
    minute: minute,
    // Cron counts Sunday as 0; Dart counts it as 7.
    weekday: cronDay == 0 ? DateTime.sunday : cronDay,
  );
}

/// A readable line for a job's schedule, whatever wrote it: our own cadences in
/// plain language, anything else as the expression it really is (honest beats
/// pretty — a wrong "Every day" would be a lie).
String describeJobCron(String expression) =>
    parseJobCron(expression)?.describe() ?? expression;

/// A day and time as the user reads it (`14/07 at 08:00`), in their own zone.
/// Shared by the task's facts and by the results it delivers into Chat, so the
/// same run is never stamped two different ways.
String jobTimeLabel(DateTime time) {
  final local = time.toLocal();
  return '${_two(local.day)}/${_two(local.month)} at '
      '${_two(local.hour)}:${_two(local.minute)}';
}

/// Cron's weekday numbering: Sunday is 0, not 7.
int _cronWeekday(int weekday) => weekday == DateTime.sunday ? 0 : weekday;

String _weekdayName(int weekday) => const {
  DateTime.monday: 'Monday',
  DateTime.tuesday: 'Tuesday',
  DateTime.wednesday: 'Wednesday',
  DateTime.thursday: 'Thursday',
  DateTime.friday: 'Friday',
  DateTime.saturday: 'Saturday',
  DateTime.sunday: 'Sunday',
}[weekday]!;

String _two(int value) => value.toString().padLeft(2, '0');
