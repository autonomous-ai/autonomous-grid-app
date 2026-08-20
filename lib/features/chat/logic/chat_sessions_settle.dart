part of 'chat_sessions_controller.dart';

/// How many turns a chat may carry on by itself before it stops and asks
/// (issue #28).
///
/// Three, because the thing being guarded against is a task that never
/// converges: the assistant is spending the user's grid — and, on a paid seat,
/// their money — on turns nobody asked for, and it does it while they are away
/// from the machine, which is the whole reason the app continues at all. Three
/// clears the ordinary case (a long job that needed one or two more budgets) and
/// still puts a floor under the pathological one. Past it the chat stops and the
/// "carry on" bar comes back, with the count in it.
const int kCarryOnTurns = 3;

/// How a turn ends: the desktop notification, the name the agent gives the
/// chat, and the bookkeeping that frees the agent's single slot and starts
/// whatever was waiting behind it.
mixin _ChatSettle on _ChatSessions {
  /// Settle one conversation's send: drop its subscription and complete the
  /// future [send] returned (whether it finished on its own or was cancelled).
  @override
  void _finish(String id) {
    _subs.remove(id);
    _turnActivityAt.remove(id);
    final done = _dones.remove(id);
    if (done != null && !done.isCompleted) done.complete();
    _releaseAgentSlot(id);
    // Before the queue and the goal below: whatever runs next re-reads this
    // chat, and the note belongs under the answer that made the claim rather
    // than after whatever the app went on to do.
    _settleLoopClaim(id);
    // The user's own words first: a follow-up they typed outranks both the
    // carry-on and the goal's next step, and those pick up again once the queue
    // is empty.
    final outcome = _lastTurn.remove(id);
    if (_drainQueue(id)) return;
    if (_carriesOnAlone(id, outcome)) return;
    unawaited(_judgeGoalTurn(id, outcome));
  }

  /// Send the assistant back in, unasked, when the last turn stopped for want of
  /// room rather than because the work was done (issue #28). True when it did.
  ///
  /// A turn that hits its tool-call budget mid-plan has produced a summary, not
  /// an answer, and the only thing standing between it and the rest of the job
  /// was a click — which is no use at all to the person who set a long task
  /// going and left the room. This is that click, up to [kCarryOnTurns] times.
  ///
  /// It stands down in three cases, each for its own reason:
  ///
  /// - **The user pressed Stop** ([outcome] is null). They have said what they
  ///   want, and carrying on would be the app arguing with them.
  /// - **A goal or a loop is running.** Those already own this chat's cadence;
  ///   a second automatic sender would spend two turns for every one the user
  ///   asked for, and the two would interleave.
  /// - **The budget is spent.** The bar comes back and says how many turns went
  ///   on it, because by then the app has spent three the user never saw.
  bool _carriesOnAlone(String id, _TurnOutcome? outcome) {
    if (outcome == null) return false;
    final spent = state.carriedOnFor(id);
    if (!willCarryOn(id)) {
      // Nothing to say unless this is the app giving up: a warning, not an info
      // line, because it has just spent turns of somebody's grid on one
      // instruction and is stopping with the work still unfinished.
      if (state.outOfStepsFor(id) && spent >= kCarryOnTurns) {
        ref
            .read(appLogProvider)
            .warn(
              'chat',
              'chat $id ran out of room again after $spent carry-on turn(s) — '
                  'stopping and asking the user',
            );
      }
      return false;
    }
    ref
        .read(appLogProvider)
        .info(
          'chat',
          'chat $id ran out of room mid-plan — carrying on by itself '
              '(${spent + 1} of $kCarryOnTurns)',
        );
    state = state.withCarriedOn(id, spent + 1);
    unawaited(continueChat(id));
    return true;
  }

  /// Whether chat [id], as things stand, is one the app would carry on by
  /// itself.
  ///
  /// Read twice: once by [_carriesOnAlone] to do it, and once by the turn that
  /// just landed to decide whether it is worth telling the desktop about (see
  /// `_announceTurn`) — a task carried on three times must not send three
  /// notifications saying it stopped, to a user who is not there precisely
  /// because the app can now finish without them.
  @override
  bool willCarryOn(String id) {
    if (!state.outOfStepsFor(id)) return false;
    if (state.carriedOnFor(id) >= kCarryOnTurns) return false;
    final chat = _find(id);
    if (chat == null) return false;
    return !(chat.goal?.isRunning ?? false) && !(chat.loop?.isRunning ?? false);
  }

  /// Cancel one conversation's in-flight reply (if any) and settle it. Also
  /// drops it from the follow-up queue: Stop means stop, so a message typed
  /// behind the turn being abandoned is abandoned with it rather than firing a
  /// second later as if nothing had happened. The composer shows what is
  /// waiting, so this is something the user can see go.
  @override
  void _cancel(String id) {
    _retryableTurns.remove(id);
    _turnActivityAt.remove(id);
    final sub = _subs.remove(id);
    sub?.cancel();
    // Not while the controller is being torn down: `_cancelAll` runs from
    // `ref.onDispose`, and Riverpod forbids touching state there. The queue is
    // in-memory anyway, so a disposal takes it with it.
    if (!_disposed) state = state.withQueue(id, const []);
    final done = _dones.remove(id);
    if (done != null && !done.isCompleted) done.complete();
    _releaseAgentSlot(id);
  }

  /// Stop counting [id] as a chat with an agent running. A no-op for a relay
  /// turn or a background chat that never ran one.
  ///
  /// Silent during disposal: this is reached from `ref.onDispose` (via
  /// [_cancelAll]) whenever the app is torn down with an agent turn in flight,
  /// and Riverpod asserts on any state written there. There is also nothing left
  /// to free — the whole controller is going.
  void _releaseAgentSlot(String id) {
    if (_disposed || !state.runningAgents.containsKey(id)) return;
    state = state.copyWith(
      runningAgents: {
        for (final running in state.runningAgents.entries)
          if (running.key != id) running.key: running.value,
      },
    );
  }

  /// Tear down every in-flight reply — for disposal.
  void _cancelAll() {
    for (final id in _subs.keys.toList()) {
      _cancel(id);
    }
  }
}
