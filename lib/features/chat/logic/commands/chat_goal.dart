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

  /// Held at the user's request, and resumable. Only a delegated goal reaches
  /// this: Codex's `thread/goal/set {status: "paused"}` is the pause button,
  /// and the app has no equivalent of its own.
  paused,

  /// The agent stopped making progress on its own terms. Distinct from
  /// [stalled] because nobody judged it — the agent said so.
  blocked,

  /// Out of plan usage, not out of ideas. Reporting this as [impossible] would
  /// tell the user their goal can never be met when what they need is to wait
  /// or upgrade, so it keeps its own name (conventions §5).
  usageLimited,

  /// The goal's own token budget ran out — see `ChatGoal.tokenBudget`. Same
  /// reasoning as [usageLimited]: a spending cap is not a verdict.
  budgetLimited,
}

/// Who advances a goal — the app, or the agent it was handed to.
///
/// Two of the three agents Grid drives ship a goal loop of their own, reachable
/// over the exact transport Grid already uses, and both are better than the
/// app's: they run tools, they see the workspace, and they are the mechanism
/// the user gets when they run that agent directly. So Grid delegates and
/// mirrors rather than running a second, weaker loop beside them.
///
/// The value is chosen **once**, when the goal is set, and then pinned with the
/// goal — see `Conversation.agentPin`. Re-reading the live agent every turn
/// would hand a half-finished goal to whoever happens to be selected.
enum GoalOwner {
  /// Grid's own evaluator loop (`chat_sessions_goals.dart`) drives it.
  ///
  /// The fallback, not the default. It is what a chat gets when its agent has
  /// no goal API of its own.
  // TODO(BE): Hermes has a real `/goal` (set/draft/show/pause/resume/clear) but
  // it lives in its own TUI, and the ACP server Grid talks to advertises only
  // help/model/tools/context/reset/compact/steer/queue/version. An unknown
  // command falls through to the model as prose rather than erroring, which is
  // the worst failure mode available — so Hermes runs on this fallback until
  // either ACP exposes goals or Grid moves off `hermes acp`. Not supported
  // natively today; revisit when either lands.
  app,

  /// Claude Code's session-scoped Stop hook drives it.
  ///
  /// Measured on 2.1.233: the condition is written into the session transcript
  /// as a `goal_status` sentinel, and a `--resume` re-arms the hook in the new
  /// process — so the goal outlives one invocation and keeps hold of every
  /// later turn until it is met or cleared.
  claude,

  /// Codex's thread-goal runtime drives it (`thread/goal/*`).
  codex;

  /// Whether Grid runs the evaluator itself for this owner.
  ///
  /// The one test that keeps the app from double-driving a delegated goal:
  /// judging a turn the agent is already judging spends two models on one
  /// question and lets them disagree.
  bool get isAppDriven => this == GoalOwner.app;
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
    this.owner = GoalOwner.app,
    this.turnsEvaluated = 0,
    this.reason,
    this.endedAfter,
    this.elapsed,
    this.tokensUsed,
    this.tokenBudget,
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

  /// Who advances this goal. Fixed when it is set, and never re-read from the
  /// live agent afterwards — see [GoalOwner].
  final GoalOwner owner;

  /// How long the agent says it has spent, when the agent says so.
  ///
  /// Null for [GoalOwner.app], where the bar counts from [startedAt] instead.
  /// Codex reports `timeUsedSeconds` on every `thread/goal/updated`, and its
  /// number is the honest one: it counts the work, not the wall clock, so a
  /// goal that sat paused overnight does not claim eight hours of effort.
  final Duration? elapsed;

  /// Tokens the agent reports spending on this goal, when it reports any.
  ///
  /// A goal spends the user's money while they are away from the machine, so
  /// the number belongs on screen wherever it can be had (spec §Chung).
  final int? tokensUsed;

  /// The ceiling the agent is holding itself to, when there is one. Null means
  /// unbounded — which is the honest reading of "no budget", not "zero".
  final int? tokenBudget;

  bool get isRunning => status == GoalStatus.active;

  /// Whether this goal is over and will not move again on its own.
  ///
  /// [GoalStatus.paused] is deliberately **not** here: it is held, not ended,
  /// and the bar offers Resume rather than a tombstone.
  bool get hasEnded => switch (status) {
    GoalStatus.active || GoalStatus.paused => false,
    GoalStatus.met ||
    GoalStatus.impossible ||
    GoalStatus.stalled ||
    GoalStatus.blocked ||
    GoalStatus.usageLimited ||
    GoalStatus.budgetLimited => true,
  };

  ChatGoal copyWith({
    GoalStatus? status,
    int? turnsEvaluated,
    String? reason,
    int? endedAfter,
    Duration? elapsed,
    int? tokensUsed,
    int? tokenBudget,
    // A goal that picks back up has not ended anywhere, and `?? this` cannot
    // say that.
    bool clearEndedAfter = false,
  }) => ChatGoal(
    condition: condition,
    status: status ?? this.status,
    startedAt: startedAt,
    owner: owner,
    turnsEvaluated: turnsEvaluated ?? this.turnsEvaluated,
    reason: reason ?? this.reason,
    endedAfter: clearEndedAfter ? null : (endedAfter ?? this.endedAfter),
    elapsed: elapsed ?? this.elapsed,
    tokensUsed: tokensUsed ?? this.tokensUsed,
    tokenBudget: tokenBudget ?? this.tokenBudget,
  );

  Map<String, Object?> toJson() => {
    'condition': condition,
    'status': status.name,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'owner': owner.name,
    'turnsEvaluated': turnsEvaluated,
    if (reason != null) 'reason': reason,
    if (endedAfter != null) 'endedAfter': endedAfter,
    if (elapsed != null) 'elapsedSeconds': elapsed!.inSeconds,
    if (tokensUsed != null) 'tokensUsed': tokensUsed,
    if (tokenBudget != null) 'tokenBudget': tokenBudget,
  };

  /// Null for anything this app didn't write.
  ///
  /// **The reload downgrade is owner-specific**, and getting it wrong is a lie
  /// in either direction:
  ///
  /// - [GoalOwner.app]: a goal still running when the app closed reads back
  ///   [GoalStatus.stalled], never active. The app is the thing that would fire
  ///   the next turn, and the recoverable answer is one that doesn't start
  ///   firing at a chat the moment it is opened.
  /// - [GoalOwner.claude] / [GoalOwner.codex]: it reads back **active**,
  ///   because it *is* still active — in the agent, which Grid did not restart.
  ///   Measured on `claude` 2.1.233: the condition is kept in the session
  ///   transcript as a `goal_status` sentinel and `--resume` re-arms the Stop
  ///   hook, so the next turn is taken by the goal whether Grid remembers it or
  ///   not. Downgrading here would show "paused" over a loop that is running.
  static ChatGoal? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final condition = '${raw['condition'] ?? ''}'.trim();
    final startedAt = DateTime.tryParse('${raw['startedAt']}');
    if (condition.isEmpty || startedAt == null) return null;
    final stored = GoalStatus.values.firstWhere(
      (status) => status.name == raw['status'],
      orElse: () => GoalStatus.stalled,
    );
    // Anything this app didn't write, and anything written before goals had an
    // owner, is the app's own — that is what it was when it was saved.
    final owner = GoalOwner.values.firstWhere(
      (candidate) => candidate.name == raw['owner'],
      orElse: () => GoalOwner.app,
    );
    final turns = raw['turnsEvaluated'];
    final endedAfter = raw['endedAfter'];
    final elapsedSeconds = raw['elapsedSeconds'];
    final tokensUsed = raw['tokensUsed'];
    final tokenBudget = raw['tokenBudget'];
    return ChatGoal(
      condition: condition,
      status: stored == GoalStatus.active && owner.isAppDriven
          ? GoalStatus.stalled
          : stored,
      startedAt: startedAt,
      owner: owner,
      turnsEvaluated: turns is int && turns > 0 ? turns : 0,
      reason: raw['reason'] is String ? raw['reason'] as String : null,
      endedAfter: endedAfter is int && endedAfter > 0 ? endedAfter : null,
      elapsed: elapsedSeconds is int && elapsedSeconds > 0
          ? Duration(seconds: elapsedSeconds)
          : null,
      tokensUsed: tokensUsed is int && tokensUsed >= 0 ? tokensUsed : null,
      tokenBudget: tokenBudget is int && tokenBudget > 0 ? tokenBudget : null,
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
///
/// Every arm carries [ChatGoal.reason] when there is one. It used to be two of
/// six: `met` printed only the condition, so a user whose goal was declared met
/// too early had no way to see what the evaluator thought it had seen — the
/// verdict was stored and never shown.
///
/// [GoalStatus.stalled] no longer states a cause of its own either. It was
/// hardcoded to the idle-turn story while four of the five ways a goal stalls
/// are something else entirely (Stop pressed, no model to judge with, the check
/// failed, no grid selected) — so it blamed the assistant for the user's click
/// (conventions §5: honest labels).
String goalBarLabel(ChatGoal goal, DateTime now) {
  final head = switch (goal.status) {
    GoalStatus.active => 'Working toward: ${goal.condition}',
    GoalStatus.met => 'Goal met: ${goal.condition}',
    GoalStatus.impossible => 'Stopped — this cannot be met: ${goal.condition}',
    GoalStatus.stalled => 'Goal paused: ${goal.condition}',
    GoalStatus.paused => 'Goal held: ${goal.condition}',
    GoalStatus.blocked => 'Goal blocked: ${goal.condition}',
    // Named for what it is. Reporting a plan limit as "cannot be met" tells the
    // user to give up on work that only needs them to wait.
    GoalStatus.usageLimited => 'Goal paused — out of usage: ${goal.condition}',
    GoalStatus.budgetLimited =>
      'Goal paused — token budget spent: ${goal.condition}',
  };
  return [
    head,
    if (goal.status == GoalStatus.active) elapsedLabel(goal, now),
    if (goal.status == GoalStatus.active)
      '${goal.turnsEvaluated} '
          '${goal.turnsEvaluated == 1 ? 'turn' : 'turns'} judged',
    if (goal.tokensUsed != null) _tokens(goal),
    if (goal.reason != null) goal.reason!,
  ].join(' · ');
}

/// `12s`, `1m 51s`, `2h 04m` — the agent's own count when it keeps one, the
/// wall clock otherwise.
///
/// Seconds matter at the short end: the old form floored to whole minutes, so
/// every goal read `0m` for its first minute, which is the minute the user is
/// most likely to be watching it.
String elapsedLabel(ChatGoal goal, DateTime now) {
  // Codex reports `timeUsedSeconds` and it is the better number: it counts work
  // done, so a goal held overnight does not claim the night as effort.
  final spent = goal.elapsed ?? now.difference(goal.startedAt);
  final seconds = spent.inSeconds < 0 ? 0 : spent.inSeconds;
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) return '${seconds ~/ 60}m ${seconds % 60}s';
  return '${seconds ~/ 3600}h ${(seconds % 3600) ~/ 60}m';
}

String _tokens(ChatGoal goal) {
  final used = goal.tokensUsed!;
  final budget = goal.tokenBudget;
  // No budget means unbounded, not zero — say the spend and stop there.
  return budget == null
      ? '${_compactCount(used)} tokens'
      : '${_compactCount(used)}/${_compactCount(budget)} tokens';
}

String _compactCount(int value) {
  if (value < 1000) return '$value';
  if (value < 1000000) return '${(value / 1000).toStringAsFixed(1)}k';
  return '${(value / 1000000).toStringAsFixed(1)}M';
}

/// The one dim line the composer's status strip shows while a goal is running.
///
/// Short on purpose: it sits under the composer for the whole run, next to
/// whatever else is going on, and the long form — how long it has run, the
/// evaluator's latest reason — is [goalBarLabel], which `/goal` prints on
/// demand. What has to be there is what the user set and what it has cost.
String goalStatusNote(ChatGoal goal, DateTime now) {
  final turns = goal.turnsEvaluated;
  return [
    goal.status == GoalStatus.paused
        ? 'Goal held: ${goal.condition}'
        : 'Goal: ${goal.condition}',
    elapsedLabel(goal, now),
    // Only the app's own loop judges turns; a delegated goal has none to count,
    // and printing "0 turns" beside one that is working would read as stuck.
    if (goal.owner.isAppDriven && turns > 0)
      '$turns ${turns == 1 ? 'turn' : 'turns'}',
    if (goal.tokensUsed != null) _tokens(goal),
  ].join(' · ');
}

/// The status line `/goal` prints when it is asked rather than set.
String goalStatusLine(ChatGoal? goal, DateTime now) {
  if (goal == null) return 'No goal set.';
  return goalBarLabel(goal, now);
}
