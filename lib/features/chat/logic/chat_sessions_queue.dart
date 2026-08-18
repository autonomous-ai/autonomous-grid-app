part of 'chat_sessions_controller.dart';

/// What the user typed while the chat was still answering.
///
/// It goes **into** the answer being written wherever it can: an agent turn can
/// run for minutes, and a correction that only arrives after it has finished is
/// a correction to work already done. See [_steerRunningTurn], and
/// [AgentSteeringController] for how each agent takes one.
///
/// The queue is what's left when it can't — a picture, a turn with files
/// attached, an agent that refused, or a reply coming from the grid itself
/// rather than an agent. Those wait here and go out one at a time as the chat
/// frees up.
mixin _ChatQueue on _ChatSessions {
  /// Hold [turn] until chat [id] has finished answering.
  @override
  void _enqueue(String id, QueuedTurn turn) =>
      state = state.withQueue(id, [...state.queuedFor(id), turn]);

  /// Hand [turn] to the answer already in flight in chat [id], instead of
  /// holding it back.
  ///
  /// True when the agent took it — and what the user said is written into the
  /// turn's own timeline there and then, where they said it. False leaves it to
  /// the queue.
  @override
  Future<bool> _steerRunningTurn(String id, QueuedTurn turn) async {
    // The channel into a running turn carries text: a picture, an attached file
    // or a piece of context is a different request shape, and belongs to a turn
    // of its own.
    if (turn.modality != PlaygroundModality.text) return false;
    if (turn.attachments.isNotEmpty ||
        turn.files.isNotEmpty ||
        turn.contexts.isNotEmpty) {
      return false;
    }
    if (!ref.read(agentSteeringProvider).contains(id)) return false;
    final taken = await ref
        .read(agentSteeringProvider.notifier)
        .steer(id, turn.text);
    if (!taken) return false;

    // Into the turn that is running, at the point it reached — after the
    // sentence the agent had just written, before the one it writes next. Not
    // appended to the transcript as a message of its own: that put it above the
    // whole reply, which reads as a second question asked before the agent had
    // started (see [TurnSaid]). It lands with the turn, in the message's own
    // timeline, and the phase is left exactly as it was — this chat is still
    // answering the same turn, and nothing here started a new one.
    final phase = state.phaseFor(id);
    ref
        .read(agentRunsProvider.notifier)
        .interject(
          id,
          turn.text,
          answer: phase is SendStreaming ? phase.text : '',
        );
    return true;
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
