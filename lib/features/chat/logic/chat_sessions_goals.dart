part of 'chat_sessions_controller.dart';

/// The goal loop: after every turn a second model reads the conversation and
/// says whether the user's condition holds. Not yet → the next turn goes out
/// with the reason as its brief. Met, or impossible → it stops and says which.
///
/// The rules are pure and live in `commands/chat_goal.dart`; this is what
/// persists a goal, judges a turn, and sends the next one.
mixin _ChatGoals on _ChatSessions {
  /// Set the goal of the chat on screen — starting that chat if it is still a
  /// blank compose ([_startedChat]) — and get to work on it.
  ///
  /// The first turn goes out immediately with the condition as the directive —
  /// a goal that waits for you to type something is a note to yourself.
  ///
  /// Everything that can refuse is checked *before* the chat is started, so a
  /// condition that is too long or a grid that isn't there leaves no empty
  /// conversation behind in the sidebar.
  Future<CommandOutcome?> _setGoal(String condition, String model) async {
    if (condition.length > kMaxGoalCondition) {
      return (
        message:
            'That condition is too long ($kMaxGoalCondition characters max). '
            'It is re-read on every turn, so keep it to the end state you want.',
        failed: true,
      );
    }
    if (ref.read(selectedNetworkProvider) == null) {
      return (
        message: 'No grid is selected, so there is nothing to ask.',
        failed: true,
      );
    }
    final chat = _startedChat(model);
    _saveGoal(
      chat.id,
      ChatGoal(
        condition: condition,
        status: GoalStatus.active,
        startedAt: DateTime.now(),
      ),
    );
    unawaited(_sendGoalTurn(chat.id, condition));
    return null;
  }

  /// Drop the open chat's goal. Returns what to tell the user, in Claude Code's
  /// words: it names the condition back, so "cleared" can't be confused with
  /// "there was nothing set".
  CommandOutcome _clearGoal() {
    final chat = state.active;
    final goal = chat?.goal;
    if (chat == null || goal == null) {
      return (message: 'No goal set.', failed: false);
    }
    _saveAndReplace(chat.copyWith(clearGoal: true));
    return (message: 'Goal cleared: ${goal.condition}', failed: false);
  }

  /// Judge the turn that just ended in chat [id], and start the next one if the
  /// condition still isn't met.
  ///
  /// [outcome] is null when the turn was stopped or cancelled — the user
  /// pressing Stop has said what they want, so the goal stalls rather than
  /// firing again over the top of them.
  @override
  Future<void> _judgeGoalTurn(String id, _TurnOutcome? outcome) async {
    final goal = _find(id)?.goal;
    if (goal == null || !goal.isRunning || _disposed) return;
    if (outcome == null) {
      _saveGoal(id, goal.copyWith(status: GoalStatus.stalled));
      return;
    }
    // A failed turn is not judged: the evaluator would be reading an error
    // message and would rightly say "not met", and the loop would repeat the
    // failure. Nine identical failures is not persistence.
    if (outcome.failure != null) {
      _saveGoal(
        id,
        goal.copyWith(
          status: GoalStatus.impossible,
          reason: 'the turn failed: ${outcome.failure}',
        ),
      );
      return;
    }

    final judged = goal.copyWith(turnsEvaluated: goal.turnsEvaluated + 1);
    // Nothing was done for three turns running: the assistant is talking to the
    // evaluator, not working. Hand control back with the goal still set.
    _idleGoalTurns[id] = outcome.ranSteps ? 0 : (_idleGoalTurns[id] ?? 0) + 1;
    if ((_idleGoalTurns[id] ?? 0) >= kGoalStallTurns) {
      _idleGoalTurns.remove(id);
      _saveGoal(id, judged.copyWith(status: GoalStatus.stalled));
      return;
    }

    final verdict = await _judge(id, goal.condition);
    if (_disposed || verdict == null) return;
    // Re-read: the chat may have been deleted, or its goal cleared, while the
    // evaluator was reading.
    final current = _find(id)?.goal;
    if (current == null || !current.isRunning) return;

    switch (verdict.verdict) {
      case GoalVerdict.met:
        _saveGoal(
          id,
          judged.copyWith(status: GoalStatus.met, reason: verdict.reason),
        );
      case GoalVerdict.impossible:
        _saveGoal(
          id,
          judged.copyWith(
            status: GoalStatus.impossible,
            reason: verdict.reason,
          ),
        );
      case GoalVerdict.notYet:
        _saveGoal(id, judged.copyWith(reason: verdict.reason));
        unawaited(
          _sendGoalTurn(
            id,
            goalContinuationPrompt(goal.condition, verdict.reason),
          ),
        );
    }
  }

  /// Ask the small fast model whether the condition holds. Null when there was
  /// nothing to ask or nothing readable came back — the caller leaves the goal
  /// exactly where it was rather than guessing a verdict.
  Future<({GoalVerdict verdict, String reason})?> _judge(
    String id,
    String condition,
  ) async {
    final chat = _find(id);
    final target = resolveOneShotTarget(ref);
    final log = ref.read(appLogProvider);
    if (chat == null || target == null) {
      if (chat != null) {
        _saveGoal(
          id,
          chat.goal!.copyWith(
            status: GoalStatus.stalled,
            reason: 'no model was available to judge the goal',
          ),
        );
      }
      return null;
    }
    final (reply, error) = await ref
        .read(chatTransportProvider)
        .complete(
          endpoint: target.endpoint,
          apiKey: target.apiKey,
          model: target.model,
          messages: buildGoalEvaluatorMessages(
            condition: condition,
            messages: historyForTurn(chat.messages, chat.compaction),
          ),
        )
        .timeout(
          _judgeTimeout,
          onTimeout: () =>
              (null, const ChatTransportError('judging timed out')),
        );
    if (error != null || reply == null || reply.trim().isEmpty) {
      log.warn(
        'chat',
        'goal check failed for $id: ${error?.message ?? 'empty reply'}',
      );
      final stalled = _find(id)?.goal;
      if (stalled != null && stalled.isRunning) {
        _saveGoal(
          id,
          stalled.copyWith(
            status: GoalStatus.stalled,
            reason: 'the goal check could not be made',
          ),
        );
      }
      return null;
    }
    final verdict = parseGoalVerdict(reply);
    log.info('chat', 'goal check on $id: ${verdict.verdict.name}');
    return verdict;
  }

  /// How long the evaluator gets. It reads a transcript and writes two
  /// sentences, and it runs between two turns the user is already waiting on.
  static const _judgeTimeout = Duration(seconds: 45);

  /// Send the goal's next turn into chat [id].
  Future<void> _sendGoalTurn(String id, String message) async {
    final chat = _find(id);
    final network = ref.read(selectedNetworkProvider);
    if (chat == null || chat.goal?.isRunning != true) return;
    if (network == null) {
      _saveGoal(
        id,
        chat.goal!.copyWith(
          status: GoalStatus.stalled,
          reason: 'no grid is selected, so there is nothing to ask',
        ),
      );
      return;
    }
    await send(
      network: network,
      model: chat.model,
      message: message,
      into: id,
      // Never a planning turn: a goal's whole point is that it acts between
      // check-ins, and plan mode would stop for approval on every step.
      planFirst: false,
      // Every step continues the work of the one before it, so a goal stays
      // with one agent rather than being handed between them mid-objective.
      continuing: true,
    );
  }

  /// Persist [goal] onto chat [id]. Leaves `updatedAt` alone: the turns the
  /// goal sends move the chat in the sidebar on their own.
  void _saveGoal(String id, ChatGoal goal) {
    final chat = _find(id);
    if (chat == null) return;
    _saveAndReplace(chat.copyWith(goal: _stampGoalEnd(goal, chat)));
  }

  /// [goal] carrying the point in the transcript where it ended.
  ///
  /// One place rather than at each of the half-dozen endings, and it is what
  /// puts the "Goal met" line in the conversation at the moment it happened
  /// instead of over the composer for good. Stamped once: a goal that ends,
  /// then has its reason updated, ended where it first did. Cleared when a
  /// stalled goal picks back up, because then it hasn't ended at all.
  ChatGoal _stampGoalEnd(ChatGoal goal, Conversation chat) {
    if (goal.isRunning) return goal.copyWith(clearEndedAfter: true);
    if (goal.endedAfter != null) return goal;
    return goal.copyWith(endedAfter: chat.messages.length);
  }
}
