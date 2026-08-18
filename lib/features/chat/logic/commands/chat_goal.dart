import '../../../playground/logic/chat_message.dart';

/// Where a goal has got to.
///
/// Four endings, and they are not the same thing. The bar that showed one word
/// for all of them is what shipped issue #33; naming them separately is what
/// makes "it finished" impossible to confuse with "it gave up".
enum GoalStatus {
  /// Still going: each finished turn is judged, and an unmet condition starts
  /// the next one.
  active,

  /// The evaluator said the condition holds.
  met,

  /// The evaluator said the condition can never hold. The reason is kept.
  impossible,

  /// Several turns in a row did no work — the assistant is answering the
  /// evaluator rather than moving. The loop stops and hands back control; the
  /// goal stays set, so the next thing the user says picks it up again.
  stalled,
}

/// A completion condition the assistant works toward across turns.
///
/// Modelled on Claude Code's `/goal`, deliberately including the part Grid got
/// wrong the first time: **there is no turn or minute ceiling**. A goal ends
/// when a model reading the conversation says the condition holds, or says it
/// never can. Grid's own agent turns routinely run 40 minutes, so any number
/// the app picked would be a number that stopped real work — which is exactly
/// what a 30-minute default did in issue #33. A user who wants a bound writes
/// one into the condition ("…or stop after 20 turns"), where the evaluator can
/// read it.
class ChatGoal {
  const ChatGoal({
    required this.condition,
    required this.status,
    required this.startedAt,
    this.turnsEvaluated = 0,
    this.reason,
    this.endedAfter,
  });

  /// What has to be true for the work to be done, in the user's words. Sent to
  /// the evaluator on every turn, and to the assistant as the directive.
  final String condition;

  final GoalStatus status;

  /// When it was set — what the bar counts from.
  final DateTime startedAt;

  /// How many turns the evaluator has judged.
  final int turnsEvaluated;

  /// The evaluator's most recent reason. While the goal runs this is what the
  /// assistant is told to work on next; once it ends it is why it ended.
  final String? reason;

  /// How many messages the chat held when the goal ended — the point in the
  /// transcript where the line saying so is drawn, the way `/compact` draws its
  /// divider where it folded.
  ///
  /// Null while it runs, and null again if a stalled goal picks back up. Without
  /// it the news would sit at the end of the transcript and slide down under
  /// whatever is said next, ending up somewhere it never happened.
  final int? endedAfter;

  bool get isRunning => status == GoalStatus.active;

  ChatGoal copyWith({
    GoalStatus? status,
    int? turnsEvaluated,
    String? reason,
    int? endedAfter,
    // A goal that picks back up has not ended anywhere, and `?? this` cannot
    // say that.
    bool clearEndedAfter = false,
  }) => ChatGoal(
    condition: condition,
    status: status ?? this.status,
    startedAt: startedAt,
    turnsEvaluated: turnsEvaluated ?? this.turnsEvaluated,
    reason: reason ?? this.reason,
    endedAfter: clearEndedAfter ? null : (endedAfter ?? this.endedAfter),
  );

  Map<String, Object?> toJson() => {
    'condition': condition,
    'status': status.name,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'turnsEvaluated': turnsEvaluated,
    if (reason != null) 'reason': reason,
    if (endedAfter != null) 'endedAfter': endedAfter,
  };

  /// Null for anything this app didn't write.
  ///
  /// A goal that was still running when the app closed reads back as
  /// [GoalStatus.stalled], never active: the recoverable answer is one that
  /// doesn't start firing turns at a chat the moment it is opened.
  static ChatGoal? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final condition = '${raw['condition'] ?? ''}'.trim();
    final startedAt = DateTime.tryParse('${raw['startedAt']}');
    if (condition.isEmpty || startedAt == null) return null;
    final stored = GoalStatus.values.firstWhere(
      (status) => status.name == raw['status'],
      orElse: () => GoalStatus.stalled,
    );
    final turns = raw['turnsEvaluated'];
    final endedAfter = raw['endedAfter'];
    return ChatGoal(
      condition: condition,
      status: stored == GoalStatus.active ? GoalStatus.stalled : stored,
      startedAt: startedAt,
      turnsEvaluated: turns is int && turns > 0 ? turns : 0,
      reason: raw['reason'] is String ? raw['reason'] as String : null,
      endedAfter: endedAfter is int && endedAfter > 0 ? endedAfter : null,
    );
  }
}

/// The longest condition accepted, matching Claude Code's. A condition is read
/// by a model on every single turn, so a novel in it is a novel paid for again
/// and again.
const int kMaxGoalCondition = 4000;

/// The words that clear a goal instead of setting one — Claude Code's set, so
/// muscle memory carries across.
const Set<String> kGoalClearWords = {
  'clear',
  'stop',
  'off',
  'reset',
  'none',
  'cancel',
};

/// How many judged turns in a row may do no work before the loop gives up.
///
/// Three, not one: an assistant that answers in prose for a turn may well be
/// thinking, and cutting it off at the first is how a goal becomes useless. By
/// the third the pattern is not thinking, it is a loop.
const int kGoalStallTurns = 3;

/// What the evaluator can say.
enum GoalVerdict { met, notYet, impossible }

/// The verdict [reply] carries, and the reason it gave.
///
/// The evaluator is asked for a verdict word on its own first line. Anything
/// unreadable is [GoalVerdict.notYet]: a goal must never be declared met (or
/// hopeless) because a model wandered off format — the cost of guessing wrong
/// that way is silently stopping work the user asked for.
({GoalVerdict verdict, String reason}) parseGoalVerdict(String reply) {
  final lines = reply.trim().split('\n');
  final head = lines.isEmpty ? '' : lines.first.trim().toUpperCase();
  final reason = lines.skip(1).join('\n').trim();
  final verdict = switch (head) {
    _ when head.startsWith('MET') => GoalVerdict.met,
    _ when head.startsWith('IMPOSSIBLE') => GoalVerdict.impossible,
    _ => GoalVerdict.notYet,
  };
  return (
    verdict: verdict,
    reason: reason.isEmpty ? _fallbackReason(verdict) : reason,
  );
}

String _fallbackReason(GoalVerdict verdict) => switch (verdict) {
  GoalVerdict.met => 'The condition holds.',
  GoalVerdict.notYet => 'Not there yet.',
  GoalVerdict.impossible => 'The condition cannot be satisfied.',
};

/// What the evaluator is asked, given the [condition] and the conversation so
/// far.
///
/// It judges what the assistant has *surfaced* — it runs no tools and reads no
/// files, exactly like Claude Code's. So the prompt says so, rather than
/// letting a model imagine it checked something.
List<Map<String, String>> buildGoalEvaluatorMessages({
  required String condition,
  required List<ChatMessage> messages,
}) {
  final transcript = [
    for (final message in messages)
      if (message.text.trim().isNotEmpty)
        '${message.role == ChatRole.user ? 'User' : 'Assistant'}: '
            '${message.text.trim()}',
  ].join('\n\n');
  return [
    {
      'role': 'system',
      'content':
          'You judge whether a stated condition has been met, using only what '
          'the conversation shows. You cannot run commands or read files: if '
          'the assistant has not shown the evidence, the condition is not met. '
          'Reply with exactly one word on the first line — MET, NOT_YET or '
          'IMPOSSIBLE — then one or two sentences saying why. Say IMPOSSIBLE '
          'only when no amount of further work could satisfy the condition.',
    },
    {
      'role': 'user',
      'content': 'Condition:\n$condition\n\nConversation:\n$transcript',
    },
  ];
}

/// What is sent to start the next turn.
///
/// Carries the condition every time (a long run drifts otherwise) and the
/// evaluator's reason, which is the one piece of information the assistant does
/// not already have: what a fresh reader thinks is still missing.
String goalContinuationPrompt(String condition, String reason) =>
    'Keep working toward this goal:\n\n$condition\n\n'
    'A reviewer looking at the conversation says it is not met yet: $reason\n\n'
    'Do the next useful piece of work now — do not ask what to do next, and do '
    'not simply restate progress.';

/// The one line the goal bar shows, given the clock the caller reads.
String goalBarLabel(ChatGoal goal, DateTime now) => switch (goal.status) {
  GoalStatus.active =>
    'Working toward: ${goal.condition} · ${_elapsed(goal, now)} · '
        '${goal.turnsEvaluated} '
        '${goal.turnsEvaluated == 1 ? 'turn' : 'turns'} judged'
        '${goal.reason == null ? '' : ' · ${goal.reason}'}',
  GoalStatus.met => 'Goal met: ${goal.condition}',
  GoalStatus.impossible =>
    'Stopped — this cannot be met: ${goal.reason ?? goal.condition}',
  GoalStatus.stalled =>
    'Paused after $kGoalStallTurns turns with no work done. The goal is still '
        'set — say something and it picks up again.',
};

/// The one dim line the composer's status strip shows while a goal is running.
///
/// Short on purpose: it sits under the composer for the whole run, next to
/// whatever else is going on, and the long form — how long it has run, the
/// evaluator's latest reason — is [goalBarLabel], which `/goal` prints on
/// demand. What has to be there is what the user set and what it has cost.
String goalStatusNote(ChatGoal goal) {
  final turns = goal.turnsEvaluated;
  if (turns == 0) return 'Goal: ${goal.condition}';
  return 'Goal: ${goal.condition} · $turns ${turns == 1 ? 'turn' : 'turns'}';
}

/// The status line `/goal` prints when it is asked rather than set.
String goalStatusLine(ChatGoal? goal, DateTime now) {
  if (goal == null) return 'No goal set.';
  return goalBarLabel(goal, now);
}

String _elapsed(ChatGoal goal, DateTime now) {
  final minutes = now.difference(goal.startedAt).inMinutes;
  if (minutes < 60) return '${minutes}m';
  final hours = minutes ~/ 60;
  return '${hours}h ${minutes % 60}m';
}
