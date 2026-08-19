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
    // Which agent answers is decided here, once, and carried on the goal — see
    // [ChatGoal.agent]. Under Auto that means `/goal` settles the routing this
    // chat would otherwise redo every turn: an objective handed between agents
    // mid-run is one no agent can finish, and a delegated goal would be left
    // behind in a session nobody reads from again.
    final goal = ChatGoal(
      condition: condition,
      status: GoalStatus.active,
      startedAt: DateTime.now(),
      agent: ref.read(chatAgentForProjectProvider(chat.projectId)),
      // The turn that opens the goal is the one being sent right now, so it is
      // the message after the ones already here.
      startedAfter: chat.messages.length + 1,
    );
    _saveGoal(chat.id, goal);
    // The transcript keeps the user's own words; the wire carries the command.
    // Only the opening turn needs it — measured on `claude` 2.1.233, the goal is
    // written into the session and re-arms itself on every later `--resume`, so
    // repeating it would set the same goal again rather than continue it.
    unawaited(
      _sendGoalTurn(
        chat.id,
        condition,
        agentCommand: goal.owner == GoalOwner.claude
            ? '$kClaudeGoalCommand $condition'
            : null,
      ),
    );
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
    // A delegated goal lives in the agent's own session, and dropping the app's
    // copy would only hide it: the next turn is still taken by the loop, which
    // now has nothing on screen saying so. Measured on `claude` 2.1.233 — a goal
    // survives `--resume` and captures even an unrelated prompt — so Stop has to
    // reach the agent, and it is the only way out (there is no turn ceiling).
    if (goal.owner == GoalOwner.claude) {
      unawaited(_tellClaude(chat, kClaudeGoalClear));
    }
    _saveAndReplace(chat.copyWith(clearGoal: true));
    return (message: 'Goal cleared: ${goal.condition}', failed: false);
  }

  // TODO(BE): Hold / Resume was built here and taken out again on 2026-08-18.
  // Hold worked cleanly — it stops the process and clears the goal on the
  // agent's side, leaving nothing in the transcript. **Resume is what could not
  // be done honestly**, and the blocker is `AgentSessionSlots.planTurn`: it only
  // continues a session when `history.length > live.seen`, so a resume that
  // appends no message opens a *fresh* session — arming the goal somewhere the
  // old, still-armed session cannot hear. Appending one instead put a duplicate
  // copy of the condition in the transcript on every press (five of them, in the
  // report that ended this). Running it silently is worse again: `/goal <cond>`
  // sets *and runs* the whole loop in one invocation, so the files would change
  // with nothing on screen to say why.
  //
  // The shape that would work is an assistant-only turn: no user bubble, the
  // session id taken from `Conversation.resume` rather than from the slot, and
  // the reply streamed and committed as usual. That needs a second dispatch path
  // through the send spine, which is shared by all three agents — worth doing
  // deliberately, not as a patch on a button.

  /// Stop what the agent is doing and take its goal away — quietly.
  ///
  /// **Only ever for stopping.** Arming a goal this way would set it *and run
  /// it*, in one invocation, with nothing appended to the conversation to show
  /// what happened.
  ///
  /// **The stop is the half that matters, and leaving it out is a bug that ships
  /// as "Pause doesn't work".** Claude Code arms its goal as a Stop hook inside
  /// the *running process*: clearing the goal writes the session file, which the
  /// process that is already going never re-reads. So a `/goal clear` on its own
  /// pauses nothing — the turn in flight finishes its remaining rounds and the
  /// user watches it carry on after pressing the button.
  ///
  /// Order: kill the turn, then clear, then the caller records the new state.
  /// Clearing first would leave a live process still looping against a goal
  /// nothing on screen admits to.
  ///
  /// Not through [_sendGoalTurn]: that refuses to send unless a goal is running,
  /// and every caller is changing exactly that in the same breath.
  Future<void> _tellClaude(Conversation chat, String command) async {
    final wasRunning = state.sendingFor(chat.id);
    if (wasRunning) {
      stopChat(chat.id);
      // One beat before spawning `--resume` on the same session: the kill is
      // asynchronous, and two `claude` processes writing one session transcript
      // is a race worth not taking for a delay nobody can perceive.
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (_disposed) return;
    await runClaudeSessionCommand(
      ref,
      resume: _find(chat.id)?.resume ?? chat.resume,
      model: chat.model,
      command: command,
    );
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
    // Before anything is judged: a goal that has outrun [kGoalMaxAge] hands
    // control back rather than taking one more turn. Checked here because this
    // is the one place every finished turn passes through, agent-owned or not.
    if (goal.hasOutlivedItsRun(DateTime.now())) {
      _endDormantGoal(id, goal, 'it had been running for over 12 hours');
      return;
    }
    // A delegated goal is already being judged, by the agent that owns it and
    // with tools this evaluator does not have. Running a second judgement here
    // would spend two models on one question, let them disagree, and send a
    // continuation turn on top of the one the agent is already sending.
    //
    // `isAppDriven` stays true while an owner's driver is still unwritten, so
    // this never leaves a goal with nobody advancing it — see
    // [GoalOwner.hasDriver].
    if (!goal.owner.isAppDriven) {
      _settleDelegatedGoal(id, goal, outcome);
      return;
    }
    if (outcome == null) {
      _saveGoal(id, goal.copyWith(status: GoalStatus.stalled));
      return;
    }
    // A failed turn is not judged: the evaluator would be reading an error
    // message and would rightly say "not met", and the loop would repeat the
    // failure. Nine identical failures is not persistence.
    // **Stalled, not impossible.** A dropped connection, a grid that went away,
    // an agent that crashed — none of them say anything about the condition,
    // and [GoalStatus.impossible] is terminal: it was the app announcing the
    // goal could never be reached because the wifi blinked. Stalled says what
    // is true (nobody is advancing it) and is picked back up the moment the
    // user says anything, so the goal survives the outage that caused it.
    //
    // [GoalStatus.impossible] is left to the one thing that can judge it: the
    // evaluator reading the transcript and saying IMPOSSIBLE.
    if (outcome.failure != null) {
      _saveGoal(
        id,
        goal.copyWith(
          status: GoalStatus.stalled,
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

  /// Close out a turn of a goal the **agent** owns.
  ///
  /// Nothing here judges anything — the agent did that, with tools this app has
  /// none of. All this reads is whether the turn was *allowed to end*, which for
  /// a delegated goal is the verdict itself.
  ///
  /// Claude Code drives a goal by refusing to let the turn stop: every round its
  /// evaluator says "not met" comes back as a `Stop hook feedback:` message
  /// (see [ClaudeGoalNotMet]) and the agent is sent straight back in. So a turn
  /// that ends **cleanly** ended because the hook let go, and the hook only lets
  /// go once the condition holds. That is the signal — no extra process, no
  /// second model, no polling.
  ///
  /// The other two endings deliberately leave the goal alone, because the goal
  /// really is still armed inside the agent's session (measured on 2.1.233: it
  /// is written into the session transcript and re-arms on every `--resume`):
  ///
  /// - **stopped by the user** ([outcome] null) — `/goal clear` is what ends it,
  ///   and that is the Stop button beside the goal, not the one on the turn.
  /// - **the turn failed** — a dropped connection says nothing about the
  ///   condition. Claiming "met" here would close a goal that is still running.
  void _settleDelegatedGoal(String id, ChatGoal goal, _TurnOutcome? outcome) {
    if (outcome == null || outcome.failure != null) return;
    _saveGoal(
      id,
      goal.copyWith(
        status: GoalStatus.met,
        // Its own words where it gave them; the fallback says which agent
        // decided, because "met" with no reason reads as the app guessing.
        reason:
            goal.reason ??
            '${goal.agent?.name ?? 'The agent'} stopped '
                'working: the condition it was checking is satisfied.',
      ),
    );
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
  Future<void> _sendGoalTurn(
    String id,
    String message, {
    String? agentCommand,
  }) async {
    final chat = _find(id);
    final network = ref.read(selectedNetworkProvider);
    if (chat == null || chat.goal?.isRunning != true) return;
    // A turn is already running in this chat — the goal's next step would queue
    // behind it and go out into a conversation that has moved on. `/loop` has
    // guarded this since it was written (`chat_sessions_loops.dart`); the goal
    // loop reached the same race from the other side, where a user message
    // steered mid-turn settles the turn while the judgement is still reading.
    if (state.sendingFor(id)) return;
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
      agentCommand: agentCommand,
    );
  }

  /// Persist [goal] onto chat [id]. Leaves `updatedAt` alone: the turns the
  /// goal sends move the chat in the sidebar on their own.
  void _saveGoal(String id, ChatGoal goal) {
    final chat = _find(id);
    if (chat == null) return;
    _saveAndReplace(chat.copyWith(goal: _stampGoalEnd(goal, chat)));
  }

  /// Hand back every goal that was still running when the app last closed.
  ///
  /// The bug this exists for, in the order it happened: a goal was set one
  /// evening, Grid was closed, and the next morning `git pull` typed into that
  /// chat was judged against it and answered as a continuation of an eight-hour
  /// instruction — with the only way out being a button the user could not
  /// find. Nothing had gone wrong technically. The goal was simply still armed,
  /// and nothing said so.
  ///
  /// Ends them rather than resuming them, which is the opposite of what happens
  /// to a loop one line above, because the two capture different things: a loop
  /// sends a prompt of its own, and a goal takes the user's next one.
  void _standDownGoals() {
    for (final chat in state.conversations) {
      final goal = chat.goal;
      // Not just the running ones: a stalled goal is written to pick back up on
      // the next message, which across a restart is the same capture by another
      // name (see [ChatGoal.takesTheNextTurn]).
      if (goal == null || !goal.takesTheNextTurn) continue;
      _endDormantGoal(chat.id, goal, 'Grid was closed while it was running');
    }
  }

  /// End [goal] as [GoalStatus.dormant], saying [why], and take it off the
  /// agent that was holding it.
  ///
  /// The second half is what makes this real rather than cosmetic: a delegated
  /// goal lives in the agent's own session and **survives `--resume`**, so an
  /// app-side status is a label on something still running. Clearing it agent-
  /// side is the same move Stop makes, and the only one measured to work.
  void _endDormantGoal(String id, ChatGoal goal, String why) {
    final chat = _find(id);
    if (chat == null) return;
    if (goal.owner == GoalOwner.claude) {
      unawaited(_tellClaude(chat, kClaudeGoalClear));
    }
    ref
        .read(appLogProvider)
        .info('chat', 'goal in $id handed back — $why: ${goal.condition}');
    _saveGoal(id, goal.copyWith(status: GoalStatus.dormant, reason: why));
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
    return goal.copyWith(
      endedAfter: chat.messages.length,
      // How long it took, frozen here. Worked out at paint time instead it
      // would keep climbing after the goal was over — "achieved in 38s" would
      // read 4m the next time the chat was opened. Codex reports its own
      // figure on the wire, and that one wins.
      elapsed: goal.elapsed ?? DateTime.now().difference(goal.startedAt),
    );
  }
}
