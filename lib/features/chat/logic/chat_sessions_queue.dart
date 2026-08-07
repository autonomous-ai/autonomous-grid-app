part of 'chat_sessions_controller.dart';

/// What the user typed while the chat was still answering. An agent turn can
/// run for minutes, so a follow-up waits here instead of being dropped, and
/// goes out one at a time as the chat frees up.
mixin _ChatQueue on _ChatSessions {
  /// Hold [turn] until the open chat has finished answering.
  @override
  void _enqueue(QueuedTurn turn) {
    final id = state.activeId;
    if (id == null) return;
    state = state.withQueue(id, [...state.queuedFor(id), turn]);
  }

  /// Drop the follow-up at [index] in the chat [id] — the user changed their
  /// mind before it went out.
  void cancelQueued(String id, int index) {
    final waiting = [...state.queuedFor(id)];
    if (index < 0 || index >= waiting.length) return;
    waiting.removeAt(index);
    state = state.withQueue(id, waiting);
  }

  /// Send the next follow-up waiting in the chat [id], if any.
  ///
  /// One at a time, and only once the turn before it has settled: the whole
  /// point of the queue is that these are consecutive turns of one conversation,
  /// so firing them together would have them race for the agent's session.
  @override
  bool _drainQueue(String id) {
    final waiting = state.queuedFor(id);
    if (waiting.isEmpty) return false;
    final next = waiting.first;
    state = state.withQueue(id, waiting.sublist(1));
    unawaited(
      send(
        network: next.network,
        model: next.model,
        message: next.text,
        modality: next.modality,
        attachments: next.attachments,
        files: next.files,
        contexts: next.contexts,
        into: id,
      ),
    );
    return true;
  }
}
