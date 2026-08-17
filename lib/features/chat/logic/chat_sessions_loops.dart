part of 'chat_sessions_controller.dart';

/// The loop: a prompt the chat re-runs on a timer, either on the gap the user
/// gave or one the assistant picks after each iteration.
///
/// The rules are pure and live in `commands/chat_loop.dart`; this owns the
/// timers, which are the part that must never outlive the thing they belong to.
mixin _ChatLoops on _ChatSessions {
  /// Start (or replace) the open chat's repeating prompt.
  Future<CommandOutcome?> _startLoop(String argument) async {
    final chat = state.active;
    if (chat == null) {
      return (
        message: 'Open a chat first — a loop belongs to one conversation.',
        failed: true,
      );
    }
    final request = parseLoopArgument(argument);
    if (request.prompt.isEmpty) {
      return (message: kLoopUsage, failed: true);
    }
    if (ref.read(selectedNetworkProvider) == null) {
      return (
        message: 'No grid is selected, so there is nothing to ask.',
        failed: true,
      );
    }
    final now = DateTime.now();
    _saveLoop(
      chat.id,
      ChatLoop(
        prompt: request.prompt,
        interval: request.interval,
        startedAt: now,
        // The first run goes out now rather than one interval from now. A loop
        // that sits silent for two hours after you set it reads as broken, and
        // the answer to "is the deploy done" is wanted at the moment it is
        // asked as much as at any later one.
        nextAt: now,
      ),
    );
    unawaited(_runLoopIteration(chat.id));
    return null;
  }

  /// Stop the open chat's loop, if it has one.
  CommandOutcome _stopLoop() {
    final chat = state.active;
    final loop = chat?.loop;
    if (chat == null || loop == null) {
      return (message: 'Nothing is repeating in this chat.', failed: false);
    }
    _cancelLoopTimer(chat.id);
    _saveLoop(chat.id, loop.copyWith(status: LoopStatus.stopped));
    return (message: 'Stopped repeating: ${loop.prompt}', failed: false);
  }

  /// Drop the loop on chat [id] entirely — for `/clear`, and for a chat being
  /// deleted. Silent: the caller is already saying what happened.
  void _endLoop(String id) {
    _cancelLoopTimer(id);
    final chat = _find(id);
    final loop = chat?.loop;
    if (chat == null || loop == null || !loop.isRunning) return;
    _saveLoop(id, loop.copyWith(status: LoopStatus.stopped));
  }

  /// Send one iteration, then arrange the next.
  Future<void> _runLoopIteration(String id) async {
    final chat = _find(id);
    final loop = chat?.loop;
    final network = ref.read(selectedNetworkProvider);
    if (chat == null || loop == null || !loop.isRunning || _disposed) return;
    if (network == null) {
      _saveLoop(id, loop.copyWith(status: LoopStatus.stopped));
      return;
    }
    // Seven days is the ceiling, checked before spending a turn rather than
    // after — an expired loop must not get one last free run.
    if (loop.hasExpired(DateTime.now())) {
      _saveLoop(id, loop.copyWith(status: LoopStatus.expired));
      return;
    }
    // A turn is already running in this chat: skip this beat rather than queue
    // a second one behind it. Claude Code's scheduler does the same — there is
    // no catch-up for a fire that lands while the assistant is busy, because
    // running the same check twice back to back tells you nothing new.
    if (state.sendingFor(id)) {
      _armLoopTimer(id, kMinLoopInterval);
      return;
    }

    await send(
      network: network,
      model: chat.model,
      message: loop.prompt,
      into: id,
      planFirst: false,
      continuing: true,
    );
    if (_disposed) return;
    await _scheduleNextIteration(id);
  }

  /// Work out when the next iteration is due and arm the timer for it.
  Future<void> _scheduleNextIteration(String id) async {
    final chat = _find(id);
    final loop = chat?.loop;
    if (chat == null || loop == null || !loop.isRunning) return;

    final fixed = loop.interval;
    final paced = fixed == null ? await _askThePace(id, loop) : null;
    if (_disposed) return;
    // Re-read: the user may have stopped it while the pace was being chosen.
    final current = _find(id)?.loop;
    if (current == null || !current.isRunning) return;

    final delay = fixed ?? paced?.delay ?? const Duration(minutes: 10);
    final now = DateTime.now();
    _saveLoop(
      id,
      current.copyWith(
        iterations: current.iterations + 1,
        nextAt: now.add(delay),
        pacing: paced?.reason,
      ),
    );
    if (current.hasExpired(now.add(delay))) {
      // The next beat would land past the seven days, so there isn't one.
      _saveLoop(id, current.copyWith(status: LoopStatus.expired));
      return;
    }
    _armLoopTimer(id, delay);
  }

  /// Ask the assistant how long to wait, on a self-paced loop. Null when there
  /// was nobody to ask or nothing readable came back — the caller falls back to
  /// a plain ten minutes rather than stopping work the user asked for.
  Future<({Duration delay, String reason})?> _askThePace(
    String id,
    ChatLoop loop,
  ) async {
    final chat = _find(id);
    final target = resolveOneShotTarget(ref);
    if (chat == null || target == null || chat.messages.isEmpty) return null;
    final (reply, error) = await ref
        .read(chatTransportProvider)
        .complete(
          endpoint: target.endpoint,
          apiKey: target.apiKey,
          model: target.model,
          messages: buildLoopPaceMessages(
            prompt: loop.prompt,
            lastReply: chat.messages.last.text,
          ),
        )
        .timeout(
          _paceTimeout,
          onTimeout: () => (null, const ChatTransportError('pacing timed out')),
        );
    if (error != null || reply == null || reply.trim().isEmpty) {
      ref
          .read(appLogProvider)
          .warn(
            'chat',
            'loop pacing failed for $id: ${error?.message ?? 'empty reply'}',
          );
      return null;
    }
    return parseLoopDelay(reply);
  }

  /// How long the pacer gets. It answers with a number; a slow one just means
  /// the loop waits its default instead.
  static const _paceTimeout = Duration(seconds: 20);

  void _armLoopTimer(String id, Duration delay) {
    _cancelLoopTimer(id);
    _loopTimers[id] = Timer(delay, () => unawaited(_runLoopIteration(id)));
  }

  void _cancelLoopTimer(String id) {
    _loopTimers.remove(id)?.cancel();
  }

  /// Persist [loop] onto chat [id]. Leaves `updatedAt` alone: the turns it
  /// sends move the chat in the sidebar on their own.
  void _saveLoop(String id, ChatLoop loop) {
    final chat = _find(id);
    if (chat == null) return;
    _saveAndReplace(chat.copyWith(loop: loop));
  }
}
