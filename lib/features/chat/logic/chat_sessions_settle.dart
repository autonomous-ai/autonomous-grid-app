part of 'chat_sessions_controller.dart';

/// How a turn ends: the desktop notification, the name the agent gives the
/// chat, and the bookkeeping that frees the agent's single slot and starts
/// whatever was waiting behind it.
mixin _ChatSettle on _ChatSessions {
  /// Settle one conversation's send: drop its subscription and complete the
  /// future [send] returned (whether it finished on its own or was cancelled).
  @override
  void _finish(String id) {
    _subs.remove(id);
    final done = _dones.remove(id);
    if (done != null && !done.isCompleted) done.complete();
    _releaseAgentSlot(id);
    // The user's own words first: a follow-up they typed outranks the goal's
    // next step, and the goal picks up again once the queue is empty.
    final outcome = _lastTurn.remove(id);
    if (_drainQueue(id)) return;
    _advanceGoal(id, outcome);
  }

  /// Cancel one conversation's in-flight reply (if any) and settle it. Also
  /// drops it from its project's lane ([_agentQueues]) in case it was still
  /// waiting to dispatch, and from the follow-up queue: Stop means stop, so a
  /// message typed behind the turn being abandoned is abandoned with it rather
  /// than firing a second later as if nothing had happened. The composer shows
  /// what is waiting, so this is something the user can see go.
  @override
  void _cancel(String id) {
    _retryableTurns.remove(id);
    final sub = _subs.remove(id);
    sub?.cancel();
    for (final waiting in _agentQueues.values) {
      waiting.removeWhere((queued) => queued.id == id);
    }
    // Not while the controller is being torn down: `_cancelAll` runs from
    // `ref.onDispose`, and Riverpod forbids touching state there. The queue is
    // in-memory anyway, so a disposal takes it with it.
    if (!_disposed) {
      state = state.withQueue(id, const []).withLaneQueued(id, false);
    }
    final done = _dones.remove(id);
    if (done != null && !done.isCompleted) done.complete();
    _releaseAgentSlot(id);
  }

  /// Free the lane [id] was holding, then start the next turn waiting in that
  /// project. A no-op for a relay turn or a background chat that never ran an
  /// agent turn.
  ///
  /// Silent during disposal: this is reached from `ref.onDispose` (via
  /// [_cancelAll]) whenever the app is torn down with an agent turn in flight,
  /// and Riverpod asserts on any state written there. There is also nothing left
  /// to free — the whole controller is going.
  void _releaseAgentSlot(String id) {
    if (_disposed || !state.runningAgentIds.contains(id)) return;
    // The chat's own lane — read before the release, because a deleted chat has
    // no project to look up afterwards.
    final lane = _find(id)?.projectId;
    state = state.copyWith(
      runningAgentIds: {
        for (final running in state.runningAgentIds)
          if (running != id) running,
      },
    );
    if (lane != null) _pumpAgentQueue(lane);
  }

  /// Whether an agent turn is already running in [lane] — any project chat other
  /// than [except], which is the turn asking.
  @override
  bool _laneBusy(String lane, {required String except}) => state.runningAgentIds
      .any((id) => id != except && _find(id)?.projectId == lane);

  /// Dispatch the oldest turn waiting in [lane] whose chat is still around, if
  /// the lane is free. One at a time: [dispatch] takes the lane again.
  void _pumpAgentQueue(String lane) {
    final waiting = _agentQueues[lane];
    if (waiting == null) return;
    while (waiting.isNotEmpty) {
      final next = waiting.removeAt(0);
      // Skip a turn whose chat was deleted, or whose send was already settled,
      // while it waited — its future is (or will be) completed by [_cancel].
      final done = _dones[next.id];
      if (done == null || done.isCompleted || _find(next.id) == null) continue;
      next.dispatch();
      break;
    }
    if (waiting.isEmpty) _agentQueues.remove(lane);
  }

  /// Tear down every in-flight reply — for disposal.
  void _cancelAll() {
    for (final id in _subs.keys.toList()) {
      _cancel(id);
    }
    // Queued turns never got a subscription; complete their futures too.
    for (final waiting in _agentQueues.values.toList()) {
      for (final queued in waiting.toList()) {
        _cancel(queued.id);
      }
    }
  }
}
