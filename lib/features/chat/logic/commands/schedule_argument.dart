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

/// The default hour for a schedule that named a part of the day but no clock —
/// "every morning" is 8, not midnight, which is what a bare cadence would give.
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
/// Deliberately forgiving about *when* and strict about *what*: a schedule this
/// couldn't read falls back to a daily 8am the user can see and change on the
/// task, while a task with no words has nothing to run and must not be saved at
/// all.
ScheduleRequest? parseScheduleArgument(String argument) {
  final line = argument.trim();
  if (line.isEmpty) return null;
  final lower = line.toLowerCase();
  final interval = _interval(lower);
  final clock = _clock(lower);
  final schedule = JobSchedule(
    cadence:
        interval ??
        (_weekdaysOnly(lower) ? JobCadence.weekdays : JobCadence.everyDay),
    hour: clock?.hour ?? _dayPartHour(lower) ?? 8,
    minute: clock?.minute ?? 0,
  );
  final prompt = _taskWords(line);
  return prompt.isEmpty ? null : (schedule: schedule, prompt: prompt);
}

/// The repeat-through-the-day cadence the words name, or null for a once-a-day
/// one. Only the three the app offers: an interval it can't show is one the
/// user could never edit back.
JobCadence? _interval(String lower) {
  final match = RegExp(
    r'\b(mỗi|every|each)\s*(\d+)?\s*(phút|minutes?|mins?|giờ|hours?|h|m)\b',
  ).firstMatch(lower);
  if (match == null) return null;
  final count = int.tryParse(match.group(2) ?? '1') ?? 1;
  final unit = match.group(3)!;
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

/// The clock the words name — `8h`, `8:30`, `8 giờ`, `8am`, `20:15`.
({int hour, int minute})? _clock(String lower) {
  final match = RegExp(
    r'\b(\d{1,2})\s*(?::|h|giờ)\s*(\d{2})?\s*(am|pm|sáng|chiều|tối)?',
  ).firstMatch(lower);
  if (match == null) return _bareMeridiem(lower);
  return (
    hour: _toDayHour(int.parse(match.group(1)!), match.group(3)),
    minute: int.tryParse(match.group(2) ?? '') ?? 0,
  );
}

/// "at 8 pm" / "8 tối" — an hour with no separator, which the pattern above
/// needs a `:`/`h` for.
({int hour, int minute})? _bareMeridiem(String lower) {
  final match = RegExp(
    r'\b(\d{1,2})\s*(am|pm|sáng|chiều|tối)\b',
  ).firstMatch(lower);
  if (match == null) return null;
  return (
    hour: _toDayHour(int.parse(match.group(1)!), match.group(2)),
    minute: 0,
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

int? _dayPartHour(String lower) {
  for (final entry in kSpokenDayParts.entries) {
    if (RegExp('\\b${entry.key}\\b').hasMatch(lower)) return entry.value;
  }
  return null;
}

bool _weekdaysOnly(String lower) => RegExp(
  r'\b(ngày làm việc|weekday|weekdays|thứ hai đến thứ sáu)\b',
).hasMatch(lower);

/// The task, with the scheduling words taken off the front — what is left is
/// what the assistant is being asked to do.
String _taskWords(String line) => line
    .replaceFirst(
      RegExp(
        r'^\s*(nhắc (tôi|anh|em)|lên lịch|đặt lịch|schedule|remind me)\s*',
        caseSensitive: false,
      ),
      '',
    )
    .replaceFirst(
      RegExp(
        r'^\s*((mỗi|hàng|every|each)\s+\S+(\s+(ngày|day))?)\s*',
        caseSensitive: false,
      ),
      '',
    )
    .replaceFirst(
      RegExp(
        r'^\s*(lúc|vào lúc|at|about)?\s*\d{1,2}\s*(:|h|giờ)?\s*\d{0,2}\s*'
        r'(am|pm|sáng|trưa|chiều|tối)?\s*(thì|,|-)?\s*',
        caseSensitive: false,
      ),
      '',
    )
    .replaceFirst(
      RegExp(
        r'^\s*(sáng|trưa|chiều|tối|morning|noon|afternoon|evening)\s*'
        r'(mai|nay|tomorrow|today)?\s*(thì|,|-)?\s*',
        caseSensitive: false,
      ),
      '',
    )
    .trim();
