/// How often a scheduled task runs.
///
/// Two shapes, in the words people actually use: a **time of day** ("every
/// morning", "every weekday", "every Friday"), and a **short repeat** through
/// the day ("every 30 minutes", "every 2 hours") for things that need checking
/// often. Nobody has to learn cron either way.
enum JobCadence {
  everyDay('Every day'),
  weekdays('Every weekday'),
  chosenDays('On chosen days'),
  every30Min('Every 30 min', intervalMinutes: 30),
  hourly('Every hour', intervalMinutes: 60),
  every2Hours('Every 2 hours', intervalMinutes: 120);

  const JobCadence(this.label, {this.intervalMinutes});

  final String label;

  /// Minutes between runs for a repeat-through-the-day cadence; null for the
  /// time-of-day cadences (every day / weekday / week), which run once at a set
  /// [JobSchedule.hour]. Also the flag that tells the two shapes apart.
  final int? intervalMinutes;

  bool get isInterval => intervalMinutes != null;
}

/// When a task runs, in the terms the app asks the user for: a cadence, and —
/// for the time-of-day cadences — a time (and, weekly, which day).
///
/// Hermes takes either a cron expression or an `every Nm` interval, so this is
/// the one place that translates between the two. Everything else in the feature
/// works in these terms. [hour]/[minute]/[weekday] are ignored by the interval
/// cadences — they repeat through the day, with no set time.
class JobSchedule {
  const JobSchedule({
    required this.cadence,
    this.hour = 0,
    this.minute = 0,
    this.days = const {DateTime.monday},
  });

  final JobCadence cadence;

  /// 0–23, local time — the same clock the user sets it on, since Hermes's
  /// scheduler runs on this computer.
  final int hour;
  final int minute;

  /// Which days [JobCadence.chosenDays] runs on, as `DateTime.monday`…
  /// `DateTime.sunday`. Ignored by every other cadence.
  ///
  /// A set rather than one day: "Monday, Wednesday and Friday" is an ordinary
  /// way to want a task to run, and the preset list ("every day" / "every
  /// weekday" / one named day) could not express it — which pushed anyone who
  /// wanted it into writing the cron by hand in Hermes, outside the app.
  /// Never empty; the picker keeps the last day on.
  final Set<int> days;

  /// The schedule Hermes runs on: a 5-field cron (`minute hour * * weekday`) for
  /// the time-of-day cadences, or `every Nm` for an interval one.
  String toSchedule() => switch (cadence) {
    JobCadence.everyDay => '$minute $hour * * *',
    JobCadence.weekdays => '$minute $hour * * 1-5',
    JobCadence.chosenDays => '$minute $hour * * ${_cronDays(days)}',
    JobCadence.every30Min ||
    JobCadence.hourly ||
    JobCadence.every2Hours => 'every ${cadence.intervalMinutes}m',
  };

  /// A line a person can read: "Every weekday at 08:00", "Every 2 hours".
  String describe() {
    final time = '${_two(hour)}:${_two(minute)}';
    return switch (cadence) {
      JobCadence.everyDay => 'Every day at $time',
      JobCadence.weekdays => 'Every weekday at $time',
      JobCadence.chosenDays => '${_daysPhrase(days)} at $time',
      JobCadence.every30Min => 'Every 30 minutes',
      JobCadence.hourly => 'Every hour',
      JobCadence.every2Hours => 'Every 2 hours',
    };
  }
}

/// Reads one of *our* schedules back into a [JobSchedule], or null when it isn't
/// one (a job written by hand in Hermes, an interval we don't offer). Callers
/// then fall back to showing the raw expression rather than mislabelling it.
JobSchedule? parseJobSchedule(String expression) =>
    _parseInterval(expression) ?? _parseCron(expression);

/// An `every Nm` interval (Hermes stores it normalised to minutes, e.g. a
/// 2-hour task reads back as `every 120m`) mapped to the matching cadence, or
/// null for one we don't offer as a preset.
JobSchedule? _parseInterval(String expression) {
  final match = RegExp(
    r'^every\s+(\d+)m$',
    caseSensitive: false,
  ).firstMatch(expression.trim());
  if (match == null) return null;
  final minutes = int.parse(match.group(1)!);
  for (final cadence in JobCadence.values) {
    if (cadence.intervalMinutes == minutes) {
      return JobSchedule(cadence: cadence);
    }
  }
  return null;
}

JobSchedule? _parseCron(String expression) {
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
  // One day or several ("5", "1,3,5"). Anything else — a range, a step — is a
  // schedule this app did not write, and the caller shows it verbatim rather
  // than mislabelling it.
  final chosen = <int>{};
  for (final part in days.split(',')) {
    final cronDay = int.tryParse(part.trim());
    if (cronDay == null || cronDay < 0 || cronDay > 6) return null;
    // Cron counts Sunday as 0; Dart counts it as 7.
    chosen.add(cronDay == 0 ? DateTime.sunday : cronDay);
  }
  if (chosen.isEmpty) return null;
  return JobSchedule(
    cadence: JobCadence.chosenDays,
    hour: hour,
    minute: minute,
    days: chosen,
  );
}

/// A readable line for a job's schedule, whatever wrote it: our own cadences in
/// plain language, anything else as the expression it really is (honest beats
/// pretty — a wrong "Every day" would be a lie).
String describeJobSchedule(String expression) =>
    parseJobSchedule(expression)?.describe() ?? expression;

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

/// The chosen days as cron writes them, in week order: `1,3,5`. Sorted so the
/// same set always produces the same expression — a task whose cron churns
/// between saves looks edited when nothing changed.
String _cronDays(Set<int> days) =>
    (days.map(_cronWeekday).toList()..sort()).join(',');

/// "Every Monday", "Every Mon, Wed & Fri" — short names once there is more than
/// one, since the full names run past the width of the row.
String _daysPhrase(Set<int> days) {
  final ordered = days.toList()..sort();
  if (ordered.length == 1) return 'Every ${_weekdayName(ordered.first)}';
  final names = [for (final day in ordered) _shortWeekdayName(day)];
  final last = names.removeLast();
  return 'Every ${names.join(', ')} & $last';
}

String _weekdayName(int weekday) => const {
  DateTime.monday: 'Monday',
  DateTime.tuesday: 'Tuesday',
  DateTime.wednesday: 'Wednesday',
  DateTime.thursday: 'Thursday',
  DateTime.friday: 'Friday',
  DateTime.saturday: 'Saturday',
  DateTime.sunday: 'Sunday',
}[weekday]!;

String _shortWeekdayName(int weekday) => _weekdayName(weekday).substring(0, 3);

String _two(int value) => value.toString().padLeft(2, '0');
