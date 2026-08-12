part of 'chat_sessions_controller.dart';

/// The goal loop: an objective the assistant works toward across several turns,
/// inside the budget the user set. The rules live in `chat_goal.dart` — this is
/// what persists a goal and sends its next turn.
mixin _ChatGoals on _ChatSessions {
  /// Set what the open chat should work toward on its own, and start it.
  ///
  /// The first turn goes out immediately — a goal that sits there until you type
  /// something is just a note to yourself.
  Future<void> startGoal({
    required String objective,
    required int maxTurns,
    required int maxMinutes,
  }) async {
    final trimmed = objective.trim();
    final active = state.active;
    if (trimmed.isEmpty || active == null) return;
    _saveGoal(
      active.id,
      ChatGoal(
        objective: trimmed,
        status: GoalStatus.active,
        startedAt: DateTime.now(),
        maxTurns: maxTurns,
        maxMinutes: maxMinutes,
      ),
    );
    await _sendGoalTurn(active.id);
  }

  /// Stop working on the open chat's goal, keeping it and its budget so
  /// [resumeGoal] can pick it up.
  void pauseGoal() {
    final goal = state.active?.goal;
    final id = state.activeId;
    if (id == null || goal == null || !goal.isRunning) return;
    _saveGoal(id, goal.copyWith(status: GoalStatus.paused, clearNote: true));
  }

  /// Start it again — from a pause, or with the budget it was stopped by topped
  /// back up when it ran out.
  Future<void> resumeGoal() async {
    final id = state.activeId;
    final goal = state.active?.goal;
    if (id == null || goal == null || goal.isRunning) return;
    // A goal that ran out of budget can't simply be flipped back to active: it
    // would stop again on the very next turn. Resuming grants a fresh budget
    // from now — the user asking for more is the whole meaning of the button.
    _saveGoal(
      id,
      ChatGoal(
        objective: goal.objective,
        status: GoalStatus.active,
        startedAt: DateTime.now(),
        maxTurns: goal.maxTurns,
        maxMinutes: goal.maxMinutes,
      ),
    );
    await _sendGoalTurn(id);
  }

  /// Drop the goal entirely. The transcript stays; the chat goes back to being
  /// an ordinary conversation.
  void dropGoal() {
    final id = state.activeId;
    final chat = _find(id ?? '');
    if (chat == null || chat.goal == null) return;
    final cleared = chat.copyWith(clearGoal: true);
    _saveAndReplace(cleared);
  }

  /// Move the chat [id]'s goal on now that a turn has ended, and start the next
  /// one if it is still running.
  ///
  /// [outcome] is what that turn produced; null when the turn was stopped or
  /// cancelled, which counts as neither progress nor failure — the goal simply
  /// pauses, because a user pressing Stop has said what they want.
  @override
  void _advanceGoal(String id, ({String? reply, String? failure})? outcome) {
    final goal = _find(id)?.goal;
    if (goal == null || !goal.isRunning || _disposed) return;
    if (outcome == null) {
      _saveGoal(id, goal.copyWith(status: GoalStatus.paused));
      return;
    }
    final next = advanceGoal(
      goal,
      reply: outcome.reply,
      failure: outcome.failure,
      now: DateTime.now(),
    );
    _saveGoal(id, next);
    if (next.isRunning) unawaited(_sendGoalTurn(id));
  }

  /// Send the goal's next turn into the chat [id].
  Future<void> _sendGoalTurn(String id) async {
    final chat = _find(id);
    final goal = chat?.goal;
    final network = ref.read(selectedNetworkProvider);
    if (chat == null || goal == null || !goal.isRunning) return;
    // No grid to send to. Say so on the goal rather than looping on a send that
    // returns immediately — an invisible spin is worse than a stop with a
    // reason.
    if (network == null) {
      _saveGoal(
        id,
        goal.copyWith(
          status: GoalStatus.blocked,
          note: 'No grid is selected, so there is nothing to ask.',
        ),
      );
      return;
    }
    await send(
      network: network,
      model: chat.model,
      message: goalContinuationPrompt(goal.objective),
      // Never a planning turn: a goal's whole point is that it acts between
      // check-ins, and plan mode would stop for approval on every step.
      planFirst: false,
      into: id,
      // Every step continues the work of the step before it, so a goal stays
      // with one agent rather than being handed between them mid-objective.
      continuing: true,
    );
  }

  /// Persist [goal] onto the chat [id] and publish it. Leaves `updatedAt` alone:
  /// the turns the goal sends move the chat in the sidebar on their own.
  void _saveGoal(String id, ChatGoal goal) {
    final chat = _find(id);
    if (chat == null) return;
    final updated = chat.copyWith(goal: goal);
    _saveAndReplace(updated);
  }
}
