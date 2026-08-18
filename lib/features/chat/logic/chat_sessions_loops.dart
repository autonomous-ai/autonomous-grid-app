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
        continuous: request.continuous,
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

  /// Arm the timers of loops that were still running when the app last closed.
  ///
  /// The timers are in memory by nature, so before this a restart was the end
  /// of a loop: the bar came back reading "Stopped repeating…" and the only way
  /// on was `/loop` again, which starts a **new** loop — count back to zero,
  /// prompt sent again on top of the work the killed turn had already done.
  /// That is the 2026-08-18 log, where one restart made the same task get
  /// planned twice.
  ///
  /// Resuming is bounded by everything a live loop is bounded by. The seven-day
  /// ceiling is checked here, so a loop that ran out while the app was closed
  /// comes back expired instead of getting one more turn. A beat that came due
  /// in the meantime waits [loopResumeSettleProvider] rather than firing into a
  /// launch that has not read the grid yet. And every resumed loop says so in
  /// the log, because the turns it sends go out with nobody watching.
  void _resumeLoops() {
    final now = DateTime.now();
    final settle = ref.read(loopResumeSettleProvider);
    final log = ref.read(appLogProvider);
    for (final chat in state.conversations) {
      final loop = chat.loop;
      if (loop == null || !loop.isRunning) continue;
      if (loop.hasExpired(now)) {
        log.info(
          'chat',
          'loop in ${chat.id} ran out its 7 days while the app was '
              'closed: ${loop.prompt}',
        );
        _saveLoop(chat.id, loop.copyWith(status: LoopStatus.expired));
        continue;
      }
      final due = loop.nextAt.difference(now);
      final delay = due < settle ? settle : due;
      // Seconds below the minute [loopIntervalLabel] rounds to: the common case
      // here is an overdue loop waiting out the settle, and "after 0m" reads
      // like a bug in the log that has to diagnose this.
      final wait = delay.inMinutes < 1
          ? '${delay.inSeconds}s'
          : loopIntervalLabel(delay);
      log.info(
        'chat',
        'resuming loop in ${chat.id} after $wait '
            '(${loop.iterations} so far): ${loop.prompt}',
      );
      _armLoopTimer(chat.id, delay);
    }
  }

  /// [chat] as it came from a copy of the history this app was not the one
  /// writing — a restored cloud backup, an imported session — with a loop it
  /// claims to be running marked stopped.
  ///
  /// A backup is a snapshot of another machine mid-run, and that machine holds
  /// the timer. Adopting the claim here would either send every turn twice or
  /// leave a bar counting down to a beat nothing is arming, and the difference
  /// is invisible from this side. Written back to disk so the next launch
  /// doesn't resume it either; starting it here is one line in the composer,
  /// with the prompt still on the bar to copy.
  Conversation _stopForeignLoop(Conversation chat) {
    final loop = chat.loop;
    if (loop == null || !loop.isRunning || _loopTimers.containsKey(chat.id)) {
      return chat;
    }
    final stopped = chat.copyWith(
      loop: loop.copyWith(status: LoopStatus.stopped),
    );
    _store.save(stopped);
    return stopped;
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

  /// Take a finished loop off the chat, and off the screen.
  ///
  /// What the loop bar's Dismiss (and its ✕) do once the run is over. It has to
  /// *remove* the loop rather than stop it again: the bar draws whenever the
  /// chat has a loop at all, so dismissing by re-stopping an already stopped one
  /// left the same bar sitting there — with no error anywhere, because nothing
  /// had failed. It was also saved to disk, so it came back on the next launch.
  ///
  /// A running loop is never dropped this way: the bar is the only thing on
  /// screen saying turns are still going out, and waving it away would leave
  /// them going out in silence. Stop it first — which is what the bar offers
  /// while it runs.
  void dismissLoop() {
    final chat = state.active;
    final loop = chat?.loop;
    if (chat == null || loop == null || loop.isRunning) return;
    // Defensive: a stopped or expired loop has no timer left. One surviving here
    // would fire into a chat with no loop to read and simply return, but a timer
    // nobody owns is not a thing to leave running.
    _cancelLoopTimer(chat.id);
    _saveAndReplace(chat.copyWith(clearLoop: true));
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
    if (chat == null || loop == null || !loop.isRunning || _disposed) return;
    // Seven days is the ceiling, checked first — before the grid check below can
    // send an expired loop into an endless retry, and before spending a turn, so
    // an expired loop never gets one last free run.
    if (loop.hasExpired(DateTime.now())) {
      ref
          .read(appLogProvider)
          .info('chat', 'loop in $id expired after 7 days: ${loop.prompt}');
      _saveLoop(id, loop.copyWith(status: LoopStatus.expired));
      return;
    }
    final network = ref.read(selectedNetworkProvider);
    if (network == null) {
      // A grid that blinked out mid-loop is not a reason to end an all-day run:
      // a background sync empties the session for a moment and `build()` returns
      // null between reads. Skip this beat and try again shortly rather than
      // stopping for good — this was the silent "loop died after 15-30m".
      ref
          .read(appLogProvider)
          .warn('chat', 'loop in $id: no grid selected, retrying in 1m');
      _armLoopTimer(id, kMinLoopInterval);
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

    ref
        .read(appLogProvider)
        .info(
          'chat',
          'loop iteration ${loop.iterations + 1} in $id: '
              '${loop.prompt}',
        );
    // A loop runs unattended, and because the next beat is only armed once this
    // turn returns, a turn that never returns freezes the whole loop. But a turn
    // still emitting — streamed text, a status, a step — is working, not stuck,
    // however long it takes, and cutting it off would throw away real work. So
    // wait it out, and only stop it once it has gone truly silent (see
    // [_awaitTurnOrStall]).
    await _awaitTurnOrStall(
      id,
      send(
        network: network,
        model: chat.model,
        message: loop.prompt,
        into: id,
        planFirst: false,
        continuing: true,
      ),
    );
    if (_disposed) return;
    await _scheduleNextIteration(id);
  }

  /// Wait for chat [id]'s loop turn to finish, unless it hangs — makes no
  /// progress at all for [loopTurnStallProvider]'s window — in which case stop
  /// it so the caller can move on to the next beat.
  ///
  /// The test is "has it gone silent", not "has it run long": a turn still
  /// streaming is doing the work the loop asked for, and a long turn that keeps
  /// talking is not the bug. Only one that has emitted nothing for the whole
  /// window is treated as hung — a `claude -p` that answered once and then sat
  /// there — and stopped with [stopChat], which keeps any partial it left.
  Future<void> _awaitTurnOrStall(String id, Future<void> turn) async {
    final window = ref.read(loopTurnStallProvider);
    var finished = false;
    unawaited(turn.whenComplete(() => finished = true));
    while (!finished && !_disposed) {
      final since = _turnActivityAt[id] ?? DateTime.now();
      final remaining = window - DateTime.now().difference(since);
      if (remaining <= Duration.zero) {
        ref
            .read(appLogProvider)
            .warn(
              'chat',
              'loop turn in $id made no progress for ${loopIntervalLabel(window)} — '
                  'treating it as hung, stopping it and moving on',
            );
        stopChat(id);
        return;
      }
      // Wake on whichever comes first: the turn ending, or the stall window
      // elapsing. The timer is cancelled after, so a finished turn leaves none
      // pending — no hour-long timer outliving a turn that ended in seconds.
      final tick = Completer<void>();
      final timer = Timer(remaining, () {
        if (!tick.isCompleted) tick.complete();
      });
      await Future.any<void>([turn, tick.future]);
      timer.cancel();
    }
  }

  /// Work out when the next iteration is due and arm the timer for it.
  Future<void> _scheduleNextIteration(String id) async {
    final chat = _find(id);
    final loop = chat?.loop;
    if (chat == null || loop == null || !loop.isRunning) return;

    // Continuous: the next turn goes out the moment this one ended — a short
    // settle, not a wait, and no pacer to ask. Fixed uses the user's number; a
    // self-paced loop asks the assistant how long to wait.
    final fixed = loop.interval;
    final paced = (fixed == null && !loop.isContinuous)
        ? await _askThePace(id, loop)
        : null;
    if (_disposed) return;
    // Re-read: the user may have stopped it while the pace was being chosen.
    final current = _find(id)?.loop;
    if (current == null || !current.isRunning) return;

    final delay = loop.isContinuous
        ? ref.read(loopContinuousGapProvider)
        : (fixed ?? paced?.delay ?? const Duration(minutes: 10));
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
          kLoopPaceTimeout,
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
