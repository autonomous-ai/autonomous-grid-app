/// Where a repeating prompt has got to.
enum LoopStatus {
  /// Waiting for the next iteration, or running one.
  running,

  /// The user stopped it.
  stopped,

  /// Seven days passed. A forgotten loop is bounded rather than eternal.
  expired,
}

/// A prompt the chat re-runs on its own, either on a fixed interval or at a
/// pace it picks each time.
///
/// Modelled on Claude Code's `/loop`, including its seven-day ceiling and its
/// two modes. The difference from [ChatGoal] is what starts the next turn: a
/// goal starts one the moment the last finished, a loop starts one when time
/// has passed. So a loop is for watching something that changes on its own — a
/// deploy, a PR, a build — and a goal is for finishing something.
class ChatLoop {
  const ChatLoop({
    required this.prompt,
    required this.interval,
    required this.startedAt,
    required this.nextAt,
    this.status = LoopStatus.running,
    this.iterations = 0,
    this.pacing,
  });

  /// What is re-run each time, in the user's words.
  final String prompt;

  /// The fixed gap between iterations, or null when the assistant picks the
  /// gap itself after each one.
  final Duration? interval;

  final DateTime startedAt;

  /// When the next iteration is due. What the bar counts down to, and what
  /// survives a restart as the record of what *would* have happened.
  final DateTime nextAt;

  final LoopStatus status;
  final int iterations;

  /// Why the assistant chose the gap it did, on a self-paced loop. Null on a
  /// fixed one, where the gap is the user's own number and needs no reason.
  final String? pacing;

  bool get isRunning => status == LoopStatus.running;

  bool get isSelfPaced => interval == null;

  /// Whether [now] is past the seven days a loop may live.
  bool hasExpired(DateTime now) => now.difference(startedAt) >= kLoopExpiry;

  ChatLoop copyWith({
    LoopStatus? status,
    DateTime? nextAt,
    int? iterations,
    String? pacing,
  }) => ChatLoop(
    prompt: prompt,
    interval: interval,
    startedAt: startedAt,
    nextAt: nextAt ?? this.nextAt,
    status: status ?? this.status,
    iterations: iterations ?? this.iterations,
    pacing: pacing ?? this.pacing,
  );

  Map<String, Object?> toJson() => {
    'prompt': prompt,
    if (interval != null) 'intervalSeconds': interval!.inSeconds,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'nextAt': nextAt.toUtc().toIso8601String(),
    'status': status.name,
    'iterations': iterations,
    if (pacing != null) 'pacing': pacing,
  };

  /// Null for anything this app didn't write.
  ///
  /// A loop that was running when the app closed reads back **stopped**. Claude
  /// Code's own tasks only fire while it is running, and re-arming a timer at
  /// launch — against a chat the user may not even open — is how a forgotten
  /// loop becomes a machine that talks to itself overnight.
  static ChatLoop? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final prompt = '${raw['prompt'] ?? ''}'.trim();
    final startedAt = DateTime.tryParse('${raw['startedAt']}');
    final nextAt = DateTime.tryParse('${raw['nextAt']}');
    if (prompt.isEmpty || startedAt == null || nextAt == null) return null;
    final seconds = raw['intervalSeconds'];
    final stored = LoopStatus.values.firstWhere(
      (status) => status.name == raw['status'],
      orElse: () => LoopStatus.stopped,
    );
    final iterations = raw['iterations'];
    return ChatLoop(
      prompt: prompt,
      interval: seconds is int && seconds > 0
          ? Duration(seconds: seconds)
          : null,
      startedAt: startedAt,
      nextAt: nextAt,
      status: stored == LoopStatus.running ? LoopStatus.stopped : stored,
      iterations: iterations is int && iterations > 0 ? iterations : 0,
      pacing: raw['pacing'] is String ? raw['pacing'] as String : null,
    );
  }
}

/// How long a loop may live before it stops itself — Claude Code's seven days.
/// It bounds a loop the user set up and forgot, which is the only kind that
/// ever becomes a problem.
const Duration kLoopExpiry = Duration(days: 7);

/// The shortest gap allowed. A minute is Claude Code's floor too, and below it
/// a loop is not watching something, it is hammering it.
const Duration kMinLoopInterval = Duration(minutes: 1);

/// How long one iteration's turn may run before the loop gives up on it and
/// moves to the next beat.
///
/// A loop runs unattended, so a turn that hangs — a `claude -p` agent turn has
/// sat for close to five hours — has nobody there to press Stop. And because
/// the next beat is only armed once the current turn returns, a single hung
/// turn freezes the whole loop for as long as it hangs: "run all night" quietly
/// stops after one iteration. Twenty minutes is far longer than the quick checks
/// a loop is for (a deploy, a PR, a build) yet short enough that a night is not
/// lost to one stuck turn.
/// TODO(BE): make this configurable for a loop whose turns are legitimately long.
const Duration kLoopTurnCeiling = Duration(minutes: 20);

/// The bounds a self-paced loop may choose between.
const Duration kMinPacedDelay = Duration(minutes: 1);
const Duration kMaxPacedDelay = Duration(hours: 1);

/// What `/loop <argument>` asked for.
///
/// [interval] is null when the user gave none, which means the assistant paces
/// itself. [prompt] is empty when they gave no prompt either — there is nothing
/// to run, and the caller says so rather than inventing an errand.
typedef LoopRequest = ({Duration? interval, String prompt});

/// Read `5m check the deploy`, `2h`, or just `check the deploy`.
///
/// Only a **leading** interval token counts: `s`, `m`, `h`, `d` after a number.
/// Anything else is the prompt, whole. Seconds round up to the one-minute
/// floor, so `/loop 30s` is a minute rather than a promise the app can't keep.
LoopRequest parseLoopArgument(String argument) {
  final trimmed = argument.trim();
  if (trimmed.isEmpty) return (interval: null, prompt: '');
  final space = trimmed.indexOf(RegExp(r'\s'));
  final head = space < 0 ? trimmed : trimmed.substring(0, space);
  final interval = parseLoopInterval(head);
  if (interval == null) return (interval: null, prompt: trimmed);
  return (
    interval: interval,
    prompt: space < 0 ? '' : trimmed.substring(space + 1).trim(),
  );
}

/// The duration [token] names (`45s`, `5m`, `2h`, `1d`), or null when it names
/// none. Never shorter than [kMinLoopInterval].
Duration? parseLoopInterval(String token) {
  final match = RegExp(r'^(\d+)([smhd])$').firstMatch(token.toLowerCase());
  if (match == null) return null;
  final value = int.parse(match.group(1)!);
  if (value <= 0) return null;
  final span = switch (match.group(2)!) {
    's' => Duration(seconds: value),
    'm' => Duration(minutes: value),
    'h' => Duration(hours: value),
    _ => Duration(days: value),
  };
  return span < kMinLoopInterval ? kMinLoopInterval : span;
}

/// How a gap reads to a person: `5m`, `2h`, `2h 30m`.
String loopIntervalLabel(Duration interval) {
  final minutes = interval.inMinutes;
  if (minutes < 60) return '${minutes}m';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '${hours}h' : '${hours}h ${rest}m';
}

/// What the assistant is asked after a self-paced iteration.
///
/// It has just seen the answer, so it is the one that knows whether the thing
/// being watched is about to change. The reply is a number of minutes and a
/// reason, both of which the bar shows.
List<Map<String, String>> buildLoopPaceMessages({
  required String prompt,
  required String lastReply,
}) => [
  {
    'role': 'system',
    'content':
        'You decide how long to wait before repeating a task. Reply with a '
        'number of minutes between 1 and 60 on the first line, then one short '
        'sentence saying why. Wait a short time when something is actively '
        'changing, and a long time when nothing is pending.',
  },
  {
    'role': 'user',
    'content':
        'The repeating task is: $prompt\n\n'
        'This is what just came back:\n$lastReply\n\n'
        'How long should I wait before running it again?',
  },
];

/// The delay [reply] asks for, clamped to what a loop may wait, and the reason
/// given.
///
/// An unreadable reply is ten minutes: long enough not to hammer anything,
/// short enough that a loop the user is watching still moves.
({Duration delay, String reason}) parseLoopDelay(String reply) {
  final lines = reply.trim().split('\n');
  final head = lines.isEmpty ? '' : lines.first;
  final number = RegExp(r'\d+').firstMatch(head);
  final reason = lines.skip(1).join(' ').trim();
  if (number == null) {
    return (
      delay: const Duration(minutes: 10),
      reason: reason.isEmpty ? 'no pace was given, so waiting 10m' : reason,
    );
  }
  var delay = Duration(minutes: int.parse(number.group(0)!));
  if (delay < kMinPacedDelay) delay = kMinPacedDelay;
  if (delay > kMaxPacedDelay) delay = kMaxPacedDelay;
  return (delay: delay, reason: reason.isEmpty ? 'waiting a while' : reason);
}

/// The one line the loop bar shows.
String loopBarLabel(ChatLoop loop, DateTime now) => switch (loop.status) {
  LoopStatus.running =>
    'Repeating: ${loop.prompt} · ${_cadence(loop)} · '
        '${loop.iterations} so far · next in ${_untilNext(loop, now)}'
        '${loop.pacing == null ? '' : ' · ${loop.pacing}'}',
  LoopStatus.stopped => 'Stopped repeating: ${loop.prompt}',
  LoopStatus.expired =>
    'Stopped after 7 days: ${loop.prompt}. Start it again if you still need it.',
};

String _cadence(ChatLoop loop) => loop.isSelfPaced
    ? 'at a pace it picks'
    : 'every ${loopIntervalLabel(loop.interval!)}';

String _untilNext(ChatLoop loop, DateTime now) {
  final left = loop.nextAt.difference(now);
  if (left.isNegative || left.inMinutes < 1) return 'under a minute';
  return loopIntervalLabel(Duration(minutes: left.inMinutes));
}

/// What `/loop` says when it is given nothing to run.
const String kLoopUsage =
    'Say what to repeat: /loop 5m check whether the deploy finished. '
    'Leave the interval out and it picks its own pace.';
