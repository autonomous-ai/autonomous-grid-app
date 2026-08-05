/// Where a long-running goal has got to.
///
/// Four ways it can stop, and they are not the same thing: the user paused it,
/// the assistant said it was finished, it ran out of the budget it was given, or
/// a turn failed and carrying on would just fail again. A screen that showed one
/// word for all four would be the "Couldn't check for updates: You're up to
/// date!" bug in another costume (§5).
enum GoalStatus {
  /// Still going: each finished turn starts the next one.
  active,

  /// The user stopped it. Everything is kept; resuming picks up where it left.
  paused,

  /// The assistant said the objective was met.
  done,

  /// The turn or time budget ran out with the objective unmet. Only the user can
  /// grant more.
  spent,

  /// A turn failed. Repeating a failing turn nine more times is not persistence,
  /// it is a loop — so the goal stops and says what went wrong.
  blocked,
}

/// An objective the assistant works toward across several turns, inside a budget
/// the user set.
///
/// The point of this on Grid specifically: the model is running on the user's own
/// machine or their own grid, so "keep going until it's done" costs them nothing
/// per turn. The budget is there to stop a runaway, not to ration spend.
///
/// The budget is **turns and minutes**, deliberately not tokens. Grid drives
/// three different agents over three different transports and none of them
/// reports token use the app could hold to a number — a "token budget" here
/// would be a figure the app made up.
class ChatGoal {
  const ChatGoal({
    required this.objective,
    required this.status,
    required this.startedAt,
    required this.maxTurns,
    required this.maxMinutes,
    this.turnsUsed = 0,
    this.note,
  });

  /// What the user asked for, in their words — repeated to the assistant on
  /// every continuation so a long run can't drift off it.
  final String objective;

  final GoalStatus status;

  /// When the goal was set, which is what the time budget is measured from.
  final DateTime startedAt;

  /// How many turns it may take, and how long it may take them. Both are
  /// ceilings; whichever is reached first stops it.
  final int maxTurns;
  final int maxMinutes;

  /// Turns spent so far, counted on the way out so a turn in flight is already
  /// paid for.
  final int turnsUsed;

  /// Why it stopped, when the reason is worth showing — the failure that
  /// blocked it. Null while it is running or when it simply finished.
  final String? note;

  bool get isRunning => status == GoalStatus.active;

  /// Whether another turn would still be inside the budget, [now] being the
  /// clock the caller reads (passed in so this stays pure and testable).
  bool hasBudgetLeft(DateTime now) =>
      turnsUsed < maxTurns && now.difference(startedAt).inMinutes < maxMinutes;

  /// How the budget reads on the bar: "3 of 10 turns · 12 of 30 min".
  String budgetLabel(DateTime now) {
    final minutes = now.difference(startedAt).inMinutes;
    return '$turnsUsed of $maxTurns turns · $minutes of $maxMinutes min';
  }

  ChatGoal copyWith({
    GoalStatus? status,
    int? turnsUsed,
    String? note,
    bool clearNote = false,
  }) => ChatGoal(
    objective: objective,
    status: status ?? this.status,
    startedAt: startedAt,
    maxTurns: maxTurns,
    maxMinutes: maxMinutes,
    turnsUsed: turnsUsed ?? this.turnsUsed,
    note: clearNote ? null : (note ?? this.note),
  );

  Map<String, Object?> toJson() => {
    'objective': objective,
    'status': status.name,
    'startedAt': startedAt.toIso8601String(),
    'maxTurns': maxTurns,
    'maxMinutes': maxMinutes,
    'turnsUsed': turnsUsed,
    if (note != null) 'note': note,
  };

  /// Null for anything that isn't a goal this app wrote — a chat with a
  /// half-written goal opens as an ordinary chat rather than not at all.
  static ChatGoal? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final objective = '${raw['objective'] ?? ''}'.trim();
    final startedAt = DateTime.tryParse('${raw['startedAt']}');
    if (objective.isEmpty || startedAt == null) return null;
    return ChatGoal(
      objective: objective,
      // An unknown status reads as paused: the recoverable answer is one that
      // doesn't start sending turns on its own the moment a chat is opened.
      status: GoalStatus.values.firstWhere(
        (s) => s.name == raw['status'],
        orElse: () => GoalStatus.paused,
      ),
      startedAt: startedAt,
      maxTurns: _positive(raw['maxTurns'], kDefaultGoalTurns),
      maxMinutes: _positive(raw['maxMinutes'], kDefaultGoalMinutes),
      turnsUsed: _positive(raw['turnsUsed'], 0, allowZero: true),
      note: raw['note'] is String ? raw['note'] as String : null,
    );
  }

  static int _positive(Object? raw, int fallback, {bool allowZero = false}) {
    final value = raw is int ? raw : int.tryParse('$raw');
    if (value == null) return fallback;
    if (value < 0 || (!allowZero && value == 0)) return fallback;
    return value;
  }
}

/// What a new goal starts with when the user doesn't change it.
const int kDefaultGoalTurns = 10;
const int kDefaultGoalMinutes = 30;

/// The line the assistant is asked to end on when the objective is met.
///
/// A marker rather than a judgement call by the app: only the assistant knows
/// whether the thing is done, and "did the reply sound finished?" is exactly the
/// kind of guess that keeps a loop running all night.
const String kGoalDoneMarker = 'GOAL COMPLETE';

/// What gets sent to start the next turn of [objective].
///
/// Carries the objective every time — a long run drifts otherwise — and says how
/// to stop, because a goal the assistant can't end is a goal that only ever ends
/// by running out of budget.
String goalContinuationPrompt(String objective) =>
    'Continue working toward this goal:\n\n$objective\n\n'
    'Do the next useful piece of work now — do not ask what to do next. '
    'When the goal is fully met, reply with $kGoalDoneMarker on its own line '
    'and nothing else after it.';

/// Whether [reply] claims the objective is met.
///
/// Anchored to a whole line so an assistant *explaining* the convention
/// ("finish by replying GOAL COMPLETE") doesn't end its own goal.
bool goalIsComplete(String reply) => _doneLine.hasMatch(reply);

final _doneLine = RegExp('^\\s*$kGoalDoneMarker\\s*\$', multiLine: true);

/// The goal after a turn that just finished, given what the assistant said and
/// the clock — the whole state machine in one pure function.
///
/// [failure] is the error when the turn failed, null when it succeeded.
ChatGoal advanceGoal(
  ChatGoal goal, {
  String? reply,
  String? failure,
  required DateTime now,
}) {
  if (!goal.isRunning) return goal;
  final spent = goal.copyWith(turnsUsed: goal.turnsUsed + 1);
  if (failure != null) {
    return spent.copyWith(status: GoalStatus.blocked, note: failure);
  }
  if (reply != null && goalIsComplete(reply)) {
    return spent.copyWith(status: GoalStatus.done);
  }
  if (!spent.hasBudgetLeft(now)) {
    return spent.copyWith(status: GoalStatus.spent);
  }
  return spent;
}
