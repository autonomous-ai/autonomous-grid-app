import '../../../scheduled/logic/job_schedule.dart';
import 'word_edge.dart';

/// What `/schedule` was asked for: when it runs, and what it does.
typedef ScheduleRequest = ({JobSchedule schedule, String prompt});

/// What to say when `/schedule` was given nothing it could run.
///
/// Shows the shape rather than describing it: the whole point of this command
/// is that nobody has to learn a format, so the fix has to read like the thing
/// they meant to type.
const String kScheduleUsage =
    'Say when and what — "/schedule every morning at 8 summarise the inbox".';

/// The hour a part of the day means when no clock was named — "every morning"
/// is 8, not the midnight a bare cadence would have given.
const Map<String, int> kSpokenDayParts = {
  'morning': 8,
  'noon': 12,
  'afternoon': 15,
  'evening': 20,
};

/// Reads "every morning at 8, summarise the inbox" into a schedule and a task,
/// or null when the words name no task to run.
///
/// The two halves are separated **first** ([_splitTiming]), and the clock is
/// then read out of the timing half alone. Reading it out of the whole line is
/// how "restart the 3h build" became a task that fired at three in the morning:
/// a digit in the user's own words is not a time, and nothing downstream could
/// have told the difference.
///
/// Forgiving about *when* and strict about *what*: a timing this couldn't read
/// falls back to a daily 8am the user can see and change on the task, while a
/// task with no words has nothing to run and must not be saved at all.
ScheduleRequest? parseScheduleArgument(String argument) {
  final line = argument.trim();
  if (line.isEmpty) return null;
  final (timing, prompt) = _splitTiming(line);
  if (prompt.isEmpty) return null;
  final clock = _clock(timing);
  return (
    schedule: JobSchedule(
      cadence: _interval(timing) ?? _dayCadence(timing),
      hour: clock?.hour ?? _dayPartHour(timing) ?? 8,
      minute: clock?.minute ?? 0,
    ),
    prompt: prompt,
  );
}

/// The leading words that say *when*, and everything after them — the task.
///
/// Eats one timing phrase at a time from the front until none matches, so
/// "remind me at 8 tomorrow morning to call the client" gives ("remind me at 8
/// tomorrow morning", "call the client") and the interval in "every 30 minutes
/// check the deploy" leaves no stray "minutes" on the front of the task.
(String timing, String task) _splitTiming(String line) {
  var rest = line;
  final timing = StringBuffer();
  while (rest.isNotEmpty) {
    final eaten = _timingPhrases
        .map((phrase) => phrase.matchAsPrefix(rest.toLowerCase()))
        .firstWhere((match) => match != null, orElse: () => null);
    if (eaten == null) break;
    timing.write(rest.substring(0, eaten.end));
    rest = rest.substring(eaten.end).trimLeft();
  }
  return (timing.toString().toLowerCase(), rest.trim());
}

/// The phrases a "when" is built out of, longest-first inside each shape so a
/// partial match never leaves half a phrase behind.
final List<RegExp> _timingPhrases = [
  // "schedule", "remind me" — the ask itself.
  RegExp(r'^(schedule|remind me)\s*'),
  // "every 30 minutes", "every 2 hours", "each hour".
  RegExp(
    // The single-letter units only count behind a number, so a word that starts
    // with one cannot be eaten as a unit and lose the task its first letters.
    r'^(every|each)\s*'
    r'(?:(\d+)\s*(seconds?|minutes?|mins?|hours?|[smh])'
    r'|(second|minute|hour))'
    '$kAfterWord'
    r'\s*',
    unicode: true,
  ),
  // "every weekday", "every morning", "every monday".
  RegExp(
    r'^(every|each)\s+(day|morning|noon|afternoon|evening|week|weekdays?'
    r'|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b\s*',
  ),
  // "at 9", "8:30", "8pm".
  RegExp(r'^(at)?\s*\d{1,2}\s*(:|h)?\s*(\d{2})?\s*(am|pm)?\s*'),
  // "tomorrow morning" — a part of the day on its own.
  RegExp(r'^(morning|noon|afternoon|evening)\s*(tomorrow|today)?\s*'),
  // The comma joining the when to the what.
  RegExp(r'^(,|-|:)\s*'),
];

/// The repeat-through-the-day cadence the timing names, or null when it names a
/// once-a-day one. Only the three the app offers: an interval it can't show is
/// one the user could never edit back.
JobCadence? _interval(String timing) {
  final match = RegExp(
    '$kBeforeWord'
    r'(?:every|each)\s*'
    r'(?:(\d+)\s*(minutes?|mins?|hours?|[hm])'
    r'|(minute|hour))'
    '$kAfterWord',
    unicode: true,
  ).firstMatch(timing);
  if (match == null) return null;
  final unit = match.group(2) ?? match.group(3)!;
  final count = int.tryParse(match.group(1) ?? '1') ?? 1;
  final minutes = unit.startsWith('h') ? count * 60 : count;
  if (minutes <= 30) return JobCadence.every30Min;
  if (minutes <= 60) return JobCadence.hourly;
  if (minutes <= 120) return JobCadence.every2Hours;
  // Longer than the app's own presets: a daily run at that hour is the closest
  // thing it can show, and showing it is what lets the user fix it.
  return null;
}

JobCadence _dayCadence(String timing) =>
    RegExp(r'\b(weekdays?|monday to friday)\b').hasMatch(timing)
    ? JobCadence.weekdays
    : JobCadence.everyDay;

/// The clock the timing words name — `8h`, `8:30`, `at 9`, `8pm`.
({int hour, int minute})? _clock(String timing) {
  final match = RegExp(
    r'\b(?:at)?\s*(\d{1,2})\s*(?::|h)?\s*(\d{2})?\s*(am|pm)?',
  ).firstMatch(timing);
  final hour = int.tryParse(match?.group(1) ?? '');
  if (match == null || hour == null) return null;
  return (
    hour: _toDayHour(hour, match.group(3)),
    minute: int.tryParse(match.group(2) ?? '') ?? 0,
  );
}

/// A 12-hour reading pushed into the 24-hour clock the schedule keeps.
int _toDayHour(int hour, String? meridiem) {
  if (meridiem == 'pm' && hour < 12) return hour + 12;
  if (meridiem == 'am' && hour == 12) return 0;
  return hour.clamp(0, 23);
}

int? _dayPartHour(String timing) {
  for (final entry in kSpokenDayParts.entries) {
    if (RegExp('\\b${entry.key}\\b').hasMatch(timing)) return entry.value;
  }
  return null;
}
