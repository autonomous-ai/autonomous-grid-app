import '../../../scheduled/logic/job_schedule.dart';

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
  'sáng': 8,
  'morning': 8,
  'trưa': 12,
  'noon': 12,
  'chiều': 15,
  'afternoon': 15,
  'tối': 20,
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
/// "nhắc tôi 8h sáng mai gọi khách" gives ("nhắc tôi 8h sáng mai", "gọi
/// khách") and the interval in "mỗi 30 phút kiểm tra deploy" leaves no stray
/// "phút" on the front of the task.
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
  // "nhắc tôi", "schedule", "remind me" — the ask itself.
  RegExp(r'^(nhắc (tôi|anh|em)|lên lịch|đặt lịch|schedule|remind me)\s*'),
  // "mỗi 30 phút", "every 2 hours", "mỗi giờ".
  RegExp(
    // The single-letter units only count behind a number — otherwise the "s"
    // of "sáng" is one, and "mỗi sáng 8h" loses its first letters to it.
    r'^(mỗi|hàng|every|each)\s*'
    r'(?:(\d+)\s*(giây|phút|giờ|seconds?|minutes?|mins?|hours?|[smh])'
    r'|(giây|phút|giờ|second|minute|hour))\b\s*',
  ),
  // "every weekday", "mỗi sáng", "hàng ngày", "every monday".
  RegExp(
    r'^(mỗi|hàng|every|each)\s+(ngày làm việc|ngày|sáng|trưa|chiều|tối|tuần'
    r'|thứ \w+|day|morning|noon|afternoon|evening|week|weekdays?'
    r'|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b\s*',
  ),
  // "lúc 8h30", "at 9", "8:30", "8pm".
  RegExp(
    r'^(vào lúc|lúc|at)?\s*\d{1,2}\s*(:|h|giờ)?\s*(\d{2})?\s*'
    r'(am|pm|sáng|chiều|tối)?\s*',
  ),
  // "sáng mai", "tomorrow morning" — a part of the day on its own.
  RegExp(
    r'^(sáng|trưa|chiều|tối|morning|noon|afternoon|evening)\s*'
    r'(mai|nay|tomorrow|today)?\s*',
  ),
  // The comma or "thì" joining the when to the what.
  RegExp(r'^(thì|,|-|:)\s*'),
];

/// The repeat-through-the-day cadence the timing names, or null when it names a
/// once-a-day one. Only the three the app offers: an interval it can't show is
/// one the user could never edit back.
JobCadence? _interval(String timing) {
  final match = RegExp(
    r'\b(?:mỗi|every|each)\s*'
    r'(?:(\d+)\s*(phút|minutes?|mins?|giờ|hours?|[hm])'
    r'|(phút|minute|giờ|hour))\b',
  ).firstMatch(timing);
  if (match == null) return null;
  final unit = match.group(2) ?? match.group(3)!;
  final count = int.tryParse(match.group(1) ?? '1') ?? 1;
  final minutes = unit.startsWith('h') || unit.startsWith('giờ')
      ? count * 60
      : count;
  if (minutes <= 30) return JobCadence.every30Min;
  if (minutes <= 60) return JobCadence.hourly;
  if (minutes <= 120) return JobCadence.every2Hours;
  // Longer than the app's own presets: a daily run at that hour is the closest
  // thing it can show, and showing it is what lets the user fix it.
  return null;
}

JobCadence _dayCadence(String timing) =>
    RegExp(
      r'\b(ngày làm việc|weekdays?|thứ hai đến thứ sáu)\b',
    ).hasMatch(timing)
    ? JobCadence.weekdays
    : JobCadence.everyDay;

/// The clock the timing words name — `8h`, `8:30`, `8 giờ`, `at 9`, `8pm`.
({int hour, int minute})? _clock(String timing) {
  final match = RegExp(
    r'\b(?:vào lúc|lúc|at)?\s*(\d{1,2})\s*(?::|h|giờ)?\s*(\d{2})?\s*'
    r'(am|pm|sáng|chiều|tối)?',
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
  final afternoon =
      meridiem == 'pm' || meridiem == 'chiều' || meridiem == 'tối';
  if (afternoon && hour < 12) return hour + 12;
  if ((meridiem == 'am' || meridiem == 'sáng') && hour == 12) return 0;
  return hour.clamp(0, 23);
}

int? _dayPartHour(String timing) {
  for (final entry in kSpokenDayParts.entries) {
    if (RegExp('\\b${entry.key}\\b').hasMatch(timing)) return entry.value;
  }
  return null;
}
