import 'chat_command.dart';
import 'word_edge.dart';

/// A command the app owns, read out of an ordinary sentence.
///
/// [certain] separates "this can be run" from "this is missing something the
/// app would have to invent". Reading the ask *is* the decision — a sentence
/// that opens with one gets it run, address in front or not, gap named or not.
/// Only two things still stop at the composer: a schedule with no hour in it,
/// which would otherwise fire at an hour nobody chose, and a reading with no
/// task left in it, which there is no way to run at all.
///
/// The offer used to cover uncertainty too, and the extra keystroke it cost on
/// every repeat was not worth the misreads it caught: the guards that matter —
/// a refusal, a question, an ask that does not open the sentence — drop those
/// sentences before they are ever read as a command.
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
/// **Only a sentence that opens with the ask counts.** A trigger found
/// mid-sentence is somebody talking — "I'll keep working until the tests pass,
/// then push" is a plan, not `/goal`, and reading it as one costs the user the
/// message they wrote. That single rule is also what keeps refusals out: "do
/// not keep checking the deploy" does not open with the ask.
///
/// Deterministic on purpose. Asking a model would cost a round-trip on every
/// send and answer differently on two identical sentences; the set of commands
/// here is small and closed, which is exactly the case a phrase reading covers
/// and a model does not improve.
SpokenCommand? readSpokenCommand(String text) {
  final line = text.trim();
  if (line.isEmpty || line.startsWith('/')) return null;
  final lower = line.toLowerCase();
  // Questions and refusals first: both open with the words a command uses.
  if (_negated.hasMatch(lower) || _asking.hasMatch(lower)) return null;
  final spoken = _read(line, lower);
  if (spoken != null) return spoken;
  // Nothing opened the sentence — but "tao cần mày làm loop mỗi giờ" is the ask
  // with a name in front of it, and reading nothing there is what sent two
  // mornings' worth of repeats to an agent that cannot make one. The words in
  // front say who does it, not what is being asked, so what is found behind
  // them is the same instruction and runs like one.
  final addressed = _address.matchAsPrefix(lower)?.end ?? 0;
  if (addressed == 0) return null;
  return _read(line.substring(addressed), lower.substring(addressed));
}

/// The readings, in the order a sentence is tried against them. Anything that
/// names a command wins over [_readHorizon], which reads one that was asked for
/// without ever naming it.
SpokenCommand? _read(String line, String lower) =>
    _readStop(lower) ??
    _readLoop(line, lower) ??
    _readGoal(line, lower) ??
    _readSchedule(line, lower) ??
    _readHorizon(line, lower);

/// The `/command argument` line a reading stands for — what the composer is
/// filled with when it isn't certain enough to run.
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

/// Sentences that open by refusing the thing they name.
///
/// Belt and braces: the opening-word rule already drops these, because a
/// refusal puts its "no" first and the trigger second. Kept because this is the
/// failure nobody would forgive — a "don't" that starts an unattended loop.
final RegExp _negated = RegExp(
  r'^\s*(thôi|đừng|dừng lại|không|khỏi|no|do not|don.t|never)\b',
);

/// Ending one of the two things that keep running by themselves.
SpokenCommand? _readStop(String lower) {
  if (_stopLoop.hasMatch(lower)) {
    return (call: (command: ChatCommand.loop, argument: 'stop'), certain: true);
  }
  if (_clearGoal.hasMatch(lower)) {
    return (
      call: (command: ChatCommand.goal, argument: 'clear'),
      certain: true,
    );
  }
  return null;
}

final RegExp _stopLoop = RegExp(
  r'^(dừng|tắt|thôi|stop|end|cancel)\s+(cái\s+|the\s+)?(lặp|loop)',
);

final RegExp _clearGoal = RegExp(
  r'^(xoá|xóa|bỏ|huỷ|hủy|clear|drop|cancel)\s+(cái\s+|the\s+)?(mục tiêu|goal)',
);

/// "lặp lại mỗi 30 phút kiểm tra deploy" / "run a loop every hour checking CI".
///
/// A gap at the front or the back of the sentence is the rhythm: it lifts out
/// and the words left over are the task. **Only** there. A duration in the
/// middle is part of what was asked — "loop this check the last 24 hours of
/// logs" repeats a look at 24 hours of logs, it does not repeat once a day —
/// so cutting one out would invent a rhythm nobody named and leave the task in
/// pieces ("check the last of logs").
///
/// A sentence with no gap at either end is not missing anything: a `/loop`
/// with no number is the app's self-paced loop, where the assistant
/// picks the gap after each turn and can say why. So that sentence runs whole,
/// with every word the user typed still in it — including the duration that
/// was never the rhythm.
///
/// The one reading that cannot run is a rhythm with no work in it: "lặp lại
/// mỗi 30 phút" and nothing else leaves `/loop` nothing to send, so it waits
/// in the composer for the user to finish it.
SpokenCommand? _readLoop(String line, String lower) {
  final trigger = _opening(lower, _loopTriggers);
  if (trigger == null) return null;
  final rest = line.substring(trigger).trim();
  if (rest.isEmpty) return null;
  final gap = _liftInterval(rest);
  if (gap == null) {
    return (call: (command: ChatCommand.loop, argument: rest), certain: true);
  }
  final argument = gap.task.isEmpty ? gap.every : '${gap.every} ${gap.task}';
  return (
    call: (command: ChatCommand.loop, argument: argument),
    certain: gap.task.isNotEmpty,
  );
}

/// "đặt mục tiêu tests pass" / "keep going until the tests pass".
SpokenCommand? _readGoal(String line, String lower) {
  final trigger = _opening(lower, _goalTriggers);
  if (trigger == null) return null;
  final argument = line.substring(trigger).trim();
  if (argument.isEmpty) return null;
  return (call: (command: ChatCommand.goal, argument: argument), certain: true);
}

/// "nhắc tôi 8h sáng mai gọi khách" / "every morning at 8 summarise the inbox".
///
/// Certain only when a time was actually named: a schedule the app had to
/// invent an hour for is a task firing at an hour nobody chose.
SpokenCommand? _readSchedule(String line, String lower) {
  if (_opening(lower, _scheduleTriggers) == null) return null;
  // The whole line, trigger included: "every morning at 8" *is* the schedule,
  // and the words that name it have to reach the schedule reader.
  return (
    call: (command: ChatCommand.schedule, argument: line),
    certain: _hasClock.hasMatch(lower),
  );
}

/// "mày chạy ít nhất tới sáng mai" — a repeat asked for without the word.
///
/// Someone who says *run until tomorrow morning* has asked for exactly what a
/// self-paced `/loop` is, and said so plainly; they simply never reached for
/// this app's word for it. Without this the sentence went to the agent as an
/// ordinary message, which answered once, in four minutes, and stopped — the
/// user came back in the morning to a night that never happened.
///
/// The one reading that does **not** need the ask to open the sentence, because
/// a horizon is where people put it: at the end, after the work. That costs the
/// protection the opening rule gives, so two things buy it back — the phrase is
/// a closed set aimed at whoever is being asked ("chạy tới sáng", "qua đêm",
/// "run overnight"), and a refusal anywhere in front of it drops the reading,
/// since "tao không muốn mày chạy tới sáng mai" opens with neither a "no" the
/// [_negated] guard would see nor a command.
///
/// The whole sentence becomes the prompt, horizon and all: it is what they
/// asked for, and the words that say "keep going" are worth repeating to the
/// assistant that has to keep going.
SpokenCommand? _readHorizon(String line, String lower) {
  final match = _horizon.firstMatch(lower);
  if (match == null) return null;
  if (_refusal.hasMatch(lower.substring(0, match.start))) return null;
  return (call: (command: ChatCommand.loop, argument: line), certain: true);
}

/// Asking the assistant to keep going until a time of day, in either language.
final RegExp _horizon = RegExp(
  r'(?:mày|bạn|em|cậu)?\s*chạy\s+(?:liên tục\s+|ít nhất\s+|tiếp\s+)*'
  r'(?:(?:tới|đến)\s+(?:sáng|trưa|chiều|tối|khuya|mai|hôm sau)|qua đêm'
  r'|xuyên đêm|suốt đêm)'
  r'|keep (?:it |them )?(?:running|going) (?:until|through|overnight)'
  r'|run (?:it |this )?overnight',
  unicode: true,
);

/// A "no" anywhere, for the one reading that looks past the front of the
/// sentence and so cannot lean on [_negated].
final RegExp _refusal = RegExp(
  '$kBeforeWord'
  r'(?:không|đừng|khỏi|chẳng|chớ|no|not|don.t|never)'
  '$kAfterWord',
  unicode: true,
);

/// Openings that mean "repeat this".
///
/// Two shapes, because people ask for this two ways. "lặp lại mỗi 30 phút …"
/// describes the repeating; "làm loop mỗi giờ 1 lần" names the loop as a thing
/// to make, and that is the one reached for once the task is already on screen
/// and only the repeating is left to ask for. Missing the second shape is what
/// left "làm loop mỗi giờ làm 1 lần đi" to an agent on 2026-08-20, which
/// answered that the loop was on and set nothing.
final List<RegExp> _loopTriggers = [
  RegExp(r'^(làm|tạo|bật|đặt|chạy)\s+(cái\s+)?(loop|vòng lặp)\s+'),
  RegExp(r'^(làm|chuyển)\s+((nó|cái này)\s+)?thành\s+(loop|vòng lặp)\s+'),
  RegExp(r'^(run|start|make|create|set up) (a |the )?loop\s+'),
  RegExp(r'^loop (this|it)\s+'),
  RegExp(r'^(lặp lại|lặp|chạy lặp|làm lại)\s+'),
  RegExp(r'^(keep checking|check again)\s+'),
];

/// Openings that mean "work until this is true".
final List<RegExp> _goalTriggers = [
  RegExp(r'^(đặt )?mục tiêu (là |:)?'),
  RegExp(r'^set (a |the )?goal (to |of |:)?'),
  RegExp(r'^(keep going|keep working) until\s+'),
  RegExp(r'^(làm|chạy) (tới|đến) khi\s+'),
];

/// Openings that mean "run this later, on a clock".
final List<RegExp> _scheduleTriggers = [
  RegExp(r'^(nhắc tôi|nhắc anh|nhắc em|lên lịch|đặt lịch)\s+'),
  RegExp(r'^(schedule|remind me)\s+'),
  RegExp(r'^(mỗi|hàng) (ngày|sáng|tối|chiều|trưa|tuần|thứ)\b'),
  RegExp(
    r'^every (day|morning|evening|afternoon|week|monday|tuesday'
    r'|wednesday|thursday|friday|saturday|sunday|weekday)\b',
  ),
];

/// Naming who does it, before saying what to do.
///
/// Every part is optional so that it matches the way people actually stack them
/// ("tao cần mày …", "mày …", "hãy …"), and an empty match means the sentence
/// was not addressed at all — which the caller reads as "no command here".
final RegExp _address = RegExp(
  r'^((tao|tôi|mình|em|anh|chị)\s+(cần|muốn|nhờ)\s+)?'
  r'((mày|bạn|em|cậu|you)\s+)?'
  r'((hãy|làm ơn|please)\s+)?',
);

/// A time of day, in either language — what makes a schedule specific.
final RegExp _hasClock = RegExp(
  r'(\d{1,2}\s*(h|:|giờ|am|pm)|sáng|trưa|chiều|tối|morning|evening|noon)',
);

/// Where the opening ask ends, or null when [lower] doesn't open with one.
int? _opening(String lower, List<RegExp> triggers) {
  for (final trigger in triggers) {
    final match = trigger.matchAsPrefix(lower);
    if (match != null) return match.end;
  }
  return null;
}

/// The gap [rest] names and the task left when it is taken out, or null when
/// nothing at either end of the sentence is a gap.
///
/// Only the two ends count. See [_readLoop] for why a duration in the middle is
/// left where it is rather than read as the rhythm.
({String every, String task})? _liftInterval(String rest) {
  for (final anchor in [_intervalAtFront, _intervalAtBack]) {
    final match = anchor.firstMatch(rest.toLowerCase());
    if (match == null) continue;
    final task = (rest.substring(0, match.start) + rest.substring(match.end))
        .trim();
    return (every: _spell(match), task: task);
  }
  return null;
}

/// `30m` / `2h` / `45s` — the spelling `/loop` itself takes, from the words
/// people say for it.
String _spell(Match match) {
  final count = match.group(1) ?? '1';
  final unit = switch (match.group(2) ?? match.group(3) ?? 'giờ') {
    's' || 'giây' || 'second' || 'seconds' => 's',
    'h' || 'giờ' || 'hour' || 'hours' => 'h',
    _ => 'm',
  };
  return '$count$unit';
}

/// `mỗi 30 phút …` — a gap at one end of the sentence, where it lifts out
/// without breaking what is left.
final RegExp _intervalAtFront = RegExp('^$_intervalBody\\s*', unicode: true);
final RegExp _intervalAtBack = RegExp(
  '\\s*$_intervalBody\\s*\$',
  unicode: true,
);

/// `mỗi 30 phút`, `every 2 hours`, `mỗi giờ` — a gap with or without a number.
///
/// Its edges are [kBeforeWord]/[kAfterWord] rather than `\b`, which is what
/// the `unicode: true` above is for: `\b` could not match "mỗi giờ" at all.
const String _intervalBody =
    '$kBeforeWord'
    r'(?:mỗi|sau|every|each)?\s*'
    // A bare `s`/`m`/`h` only counts behind a number: without that, the "s" of
    // "sáng" is a unit and "mỗi sáng 8h" reads as an interval.
    r'(?:(\d+)\s*(giây|phút|giờ|seconds?|minutes?|mins?|hours?|[smh])'
    r'|(giây|phút|giờ|second|minute|hour))'
    '$kAfterWord';
