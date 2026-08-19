import 'chat_command.dart';

/// A command the app owns, read out of an ordinary sentence.
///
/// [certain] separates "this sentence *is* the instruction" from "this sentence
/// mentions it": certain when the sentence opens with the ask and carries
/// everything the command needs, so it can simply be run. Anything less is
/// written into the composer for the user to send, because the cost of guessing
/// wrong is a loop nobody asked for, running unattended.
typedef SpokenCommand = ({ChatCommandCall call, bool certain});

/// The command [text] is asking for, or null when it is an ordinary message.
///
/// Speaking is how this is reached — a transcript lands in the composer and
/// sends itself, and nobody dictates a leading slash: "slash loop" is
/// transcribed as the words *slash loop*, so `/loop` never arrives and the
/// instruction went to the assistant as a sentence, which set nothing. Typing
/// gets the same reading, because someone who types "lặp lại mỗi 30 phút" means
/// the same thing as someone who says it.
///
/// Deterministic on purpose. Asking a model would cost a round-trip on every
/// send and answer differently on two identical sentences; the set of commands
/// here is small and closed, which is exactly the case a phrase reading covers
/// and a model does not improve.
SpokenCommand? readSpokenCommand(String text) {
  final line = text.trim();
  if (line.isEmpty || line.startsWith('/')) return null;
  final lower = line.toLowerCase();
  // Negation and questions first, for the whole sentence: "thôi đừng lặp nữa"
  // and "mục tiêu của dự án này là gì" both open with words a command uses,
  // and neither is asking for one.
  if (_negated.hasMatch(lower) || _asking.hasMatch(lower)) return null;
  return _readStop(lower) ??
      _readLoop(line, lower) ??
      _readGoal(line, lower) ??
      _readSchedule(line, lower);
}

/// The `/command argument` line [spoken] stands for — what the composer is
/// filled with when the reading isn't certain enough to run.
String spokenCommandLine(ChatCommandCall call) {
  final argument = call.argument.trim();
  return argument.isEmpty
      ? '/${call.command.name}'
      : '/${call.command.name} $argument';
}

/// Sentences that mention a command in order to **ask about** it.
///
/// A question word at the end is the Vietnamese tell ("… là gì", "… thế nào"),
/// and one at the front is the English one. Mid-sentence is left alone: "set a
/// goal to find out what broke" is an instruction with a *what* in it.
final RegExp _asking = RegExp(
  r'\?\s*$|\b(gì|sao|thế nào|ra sao|khi nào)\s*[.!]?$'
  r'|^(what|how|why|when|which|does|is|are|can|could)\b',
);

/// Sentences that mention a command in order to refuse it.
final RegExp _negated = RegExp(
  r'\b(đừng|dừng lại|không cần|khỏi cần|no need to|do not|don.t)\b\s*'
  r'(\w+\s+){0,3}(lặp|loop|mục tiêu|goal|lịch|schedule|nhắc|remind)',
);

/// Ending one of the two things that keep running by themselves.
SpokenCommand? _readStop(String lower) {
  if (RegExp(
    r'(dừng|tắt|thôi|stop|end|cancel)\s+(cái\s+|the\s+)?(lặp|loop)',
  ).hasMatch(lower)) {
    return (call: (command: ChatCommand.loop, argument: 'stop'), certain: true);
  }
  if (RegExp(
    r'(xoá|xóa|bỏ|huỷ|hủy|clear|drop|cancel)\s+(cái\s+|the\s+)?(mục tiêu|goal)',
  ).hasMatch(lower)) {
    return (
      call: (command: ChatCommand.goal, argument: 'clear'),
      certain: true,
    );
  }
  return null;
}

/// "lặp lại mỗi 30 phút kiểm tra deploy" / "run a loop every hour checking CI".
///
/// The interval is what makes it certain: `/loop` without one is a self-paced
/// loop, which is a much bigger thing to start on a guess than a 30-minute one
/// the user said out loud.
SpokenCommand? _readLoop(String line, String lower) {
  final trigger = _firstMatch(lower, _loopTriggers);
  if (trigger == null) return null;
  final rest = _after(line, trigger.end);
  final interval = _readInterval(rest);
  final argument = interval == null
      ? rest
      : '${interval.text} ${_strip(rest, interval.match)}'.trim();
  if (argument.trim().isEmpty) return null;
  return (
    call: (command: ChatCommand.loop, argument: argument),
    certain: trigger.start == 0 && interval != null,
  );
}

/// "đặt mục tiêu tests pass" / "keep going until the tests pass".
SpokenCommand? _readGoal(String line, String lower) {
  final trigger = _firstMatch(lower, _goalTriggers);
  if (trigger == null) return null;
  final argument = _after(line, trigger.end);
  if (argument.isEmpty) return null;
  return (
    call: (command: ChatCommand.goal, argument: argument),
    certain: trigger.start == 0,
  );
}

/// "nhắc tôi 8h sáng mai gọi khách" / "every morning at 8 summarise the inbox".
///
/// Certain only when a time was actually named: a schedule the app had to
/// invent an hour for is a task firing at an hour nobody chose.
SpokenCommand? _readSchedule(String line, String lower) {
  final trigger = _firstMatch(lower, _scheduleTriggers);
  if (trigger == null) return null;
  // From the trigger, not after it: "every morning at 8" *is* the schedule, and
  // the words that name it have to reach the schedule parser.
  final argument = _after(line, trigger.start);
  if (argument.isEmpty) return null;
  return (
    call: (command: ChatCommand.schedule, argument: argument),
    certain: trigger.start == 0 && _hasClock.hasMatch(lower),
  );
}

/// Openings that mean "repeat this".
final List<RegExp> _loopTriggers = [
  RegExp(r'^(lặp lại|lặp|chạy lặp|làm lại)\s+'),
  RegExp(r'^(run|start) (a |the )?loop\s+'),
  RegExp(r'\b(lặp lại|chạy lặp)\s+(mỗi|sau)\s+'),
  RegExp(r'\b(loop (this|it)|keep checking|check again)\s+'),
];

/// Openings that mean "work until this is true".
final List<RegExp> _goalTriggers = [
  RegExp(r'^(đặt |)mục tiêu (là |:)?'),
  RegExp(r'^set (a |the )?goal (to |of |:)?'),
  RegExp(r'\bmục tiêu là\s+'),
  RegExp(r'\b(keep going|keep working) until\s+'),
  RegExp(r'^(làm|chạy) (tới|đến) khi\s+'),
];

/// Openings that mean "run this later, on a clock".
final List<RegExp> _scheduleTriggers = [
  RegExp(r'^(nhắc tôi|nhắc anh|nhắc em|lên lịch|đặt lịch)\s+'),
  RegExp(r'^(schedule|remind me)\s+'),
  RegExp(r'^(mỗi|hàng) (ngày|sáng|tối|chiều|tuần|thứ)\b'),
  RegExp(
    r'^every (day|morning|evening|afternoon|week|monday|tuesday'
    r'|wednesday|thursday|friday|saturday|sunday|weekday)\b',
  ),
];

/// A time of day, in either language — what makes a schedule specific.
final RegExp _hasClock = RegExp(
  r'(\d{1,2}\s*(h|:|giờ|am|pm)|sáng|trưa|chiều|tối|morning|evening|noon)',
);

/// An interval as `/loop` itself spells one, plus the words people say for it.
({String text, Match match})? _readInterval(String rest) {
  final lower = rest.toLowerCase();
  final spelled = RegExp(
    r'\b(\d+)\s*(s|m|h|giây|phút|giờ|min|mins|minutes'
    r'|hour|hours|seconds)\b',
  ).firstMatch(lower);
  if (spelled != null) {
    final unit = switch (spelled.group(2)!) {
      's' || 'giây' || 'seconds' => 's',
      'h' || 'giờ' || 'hour' || 'hours' => 'h',
      _ => 'm',
    };
    return (text: '${spelled.group(1)}$unit', match: spelled);
  }
  final bare = RegExp(r'\b(mỗi giờ|every hour|hàng giờ)\b').firstMatch(lower);
  return bare == null ? null : (text: '1h', match: bare);
}

/// The first trigger that matches, or null when none does.
Match? _firstMatch(String lower, List<RegExp> triggers) {
  for (final trigger in triggers) {
    final match = trigger.firstMatch(lower);
    if (match != null) return match;
  }
  return null;
}

/// What [line] says from [start] on, tidied of the joining words a sentence
/// leaves behind ("mỗi", "every") when the interval has been lifted out.
String _after(String line, int start) =>
    line.substring(start.clamp(0, line.length)).trim();

/// [rest] without the interval words, so "mỗi 30 phút kiểm tra deploy" becomes
/// the task alone — the argument `/loop` wants is `30m <task>`, not the
/// sentence with its interval said twice.
String _strip(String rest, Match interval) {
  final before = rest.substring(0, interval.start);
  final after = rest.substring(interval.end);
  return '$before $after'
      .replaceAll(
        RegExp(r'^\s*(mỗi|sau|every|each)\s*', caseSensitive: false),
        '',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
