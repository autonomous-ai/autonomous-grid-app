part of 'chat_sessions_controller.dart';

/// Putting a turn on the wire and folding the reply back into its chat.
///
/// Keyed by conversation throughout, so several chats can be answering at once
/// and a reply never lands in the transcript the user has since switched to.
mixin _ChatSend on _ChatSessions {
  /// Send [message] in the open chat — or, when [into] names one, in that chat
  /// without bringing it to the front (how a queued follow-up goes out).
  ///
  /// Typing while the open chat is still answering **queues** the message rather
  /// than dropping it: an agent turn can run for minutes, and the follow-up
  /// thought shouldn't have to be held in the user's head until it ends. The
  /// queue drains one turn at a time as the chat frees up (see [_drainQueue]).
  @override
  Future<void> send({
    required NetworkCredential network,
    required String model,
    required String message,
    PlaygroundModality modality = PlaygroundModality.text,
    List<MediaAttachment> attachments = const [],
    List<ChatFile> files = const [],
    bool? planFirst,
    String? into,
  }) async {
    final text = message.trim();
    if (text.isEmpty) return;

    if (into == null && state.sending) {
      _enqueue(
        QueuedTurn(
          network: network,
          model: model,
          text: text,
          modality: modality,
          attachments: List.unmodifiable(attachments),
          files: List.unmodifiable(files),
        ),
      );
      return;
    }

    // The chat this turn lands in. A queued follow-up names it, because by the
    // time it goes out the user may well be reading something else — and it
    // must go where it was typed, not wherever they have moved to.
    final target = into == null ? _activeOrNew(model) : _find(into);
    // The chat was deleted while its follow-up waited. Nothing to send it to.
    if (target == null) return;

    // What this chat lets the agent do — its own choice when it has one, else
    // the app's standing one. Read once here so the turn runs under the mode
    // that was on screen when Send was pressed, even if the user switches chats
    // (or modes) while it streams.
    final approval = approvalFor(target, ref.read(chatPrefsProvider).approval);

    // Plan mode's planning turn: only when the composer is set to Plan (unless
    // the caller forced it — the approve path forces it off) and the agent is
    // the one answering, since a relay/media turn has no plan/act split.
    final planTurn =
        (planFirst ?? approval == AgentApprovalMode.plan) &&
        agentAnswersTurn(
          modality: modality,
          hasAttachments: attachments.isNotEmpty,
          agentInstalled: ref.read(anyAgentInstalledProvider),
        );

    // Append the user turn and persist it up front, so an interrupted reply
    // never loses what the user typed. A new compose becomes a real, saved
    // conversation here. Attached images (vision) are saved to disk so they
    // render, persist and can be re-encoded into the request.
    final userTurn = await buildUserTurn(
      text: text,
      attachments: attachments,
      files: files,
      outputsDir: ref.read(mediaOutputsDirProvider),
    );
    final withUser = target.copyWith(
      model: model,
      updatedAt: DateTime.now(),
      messages: [...target.messages, userTurn],
    );
    // A chat is named once — from its first message, until the agent replaces
    // that with a name for what it's actually about. Re-deriving on every turn
    // would drag it back to the first line the user typed ("hi") and undo that.
    final conversation = withUser.title == kNewConversationTitle
        ? withUser.copyWith(title: deriveConversationTitle(withUser.messages))
        : withUser;
    // The send owns the open slot: make it active and clear any prior error. A
    // queued follow-up doesn't — it goes out into a chat the user may have left,
    // and nothing the app sends on its own may pull them back to it.
    _commit(conversation, phase: const SendBusy(), makeActive: into == null);

    final id = conversation.id;
    final done = _dones[id] = Completer<void>();
    final project = ref.read(projectByIdProvider(conversation.projectId));
    // Plain text goes through the agent (it can use tools and keeps the
    // conversation's context); pictures — generating one, or a turn that carries
    // attachments — go straight to the grid's chat API, which is the only one
    // that can see or make them.
    final viaAgent = agentAnswersTurn(
      modality: modality,
      hasAttachments: attachments.isNotEmpty,
      agentInstalled: ref.read(anyAgentInstalledProvider),
    );

    void dispatch() => _dispatch(
      conversation: conversation,
      network: network,
      model: model,
      modality: modality,
      attachments: attachments,
      workdir: project?.path,
      // Both the project's house rules and the facts it's been asked to
      // remember — one standing brief the agent reads on its first turn.
      instructions: project == null ? null : projectStandingBrief(project),
      planTurn: planTurn,
      approval: approval,
      viaAgent: viaAgent,
      done: done,
    );

    // Serialize agent turns (see [ChatSessionsState.runningAgentId]): a second
    // one waits its turn rather than running concurrently and corrupting the
    // first's session and permission card. The chat sits in its [SendBusy]
    // "thinking" state until the slot frees. Relay/media turns share none of
    // that and go straight out, still fully concurrent.
    if (viaAgent &&
        state.runningAgentId != null &&
        state.runningAgentId != id) {
      _agentQueue.add((id: id, dispatch: dispatch));
    } else {
      dispatch();
    }
    return done.future;
  }

  /// Send [conversation]'s turn to its [ChatSender] and fold the reply back in.
  ///
  /// Split out from [send] so an agent turn can be deferred (see [_agentQueue])
  /// and dispatched later with the same committed history. The subscription is
  /// keyed by conversation, so [stop] and disposal cancel exactly this reply and
  /// it never writes back into the wrong chat after the user has moved on.
  void _dispatch({
    required Conversation conversation,
    required NetworkCredential network,
    required String model,
    required PlaygroundModality modality,
    required List<MediaAttachment> attachments,
    required String? workdir,
    required String? instructions,
    required bool planTurn,
    required AgentApprovalMode approval,
    required bool viaAgent,
    required Completer<void> done,
  }) {
    final id = conversation.id;
    // Claim the agent's single turn slot — released on finish/stop, which then
    // starts the next queued agent turn — and with it the files this turn is
    // about to change, so its undo stays with this chat even when the user has
    // moved to another one by the time the agent writes.
    if (viaAgent) {
      state = state.copyWith(runningAgentId: id);
      ref.read(agentChangesProvider.notifier).attributeTo(id);
    }

    // How long the answer takes, timed from here rather than from `send`: an
    // agent turn can sit in the queue behind another chat, and charging it for
    // that wait would tell the user this model is slow when another chat was
    // simply holding the slot.
    final clock = Stopwatch()..start();
    // When the first word of the answer appeared. Set once, on the first
    // streamed text: every later update carries the whole answer so far, so
    // reading any of them would time the last word instead of the first.
    Duration? firstToken;

    final updates = _senderFor(modality, attachments).send(
      network: network,
      model: model,
      history: conversation.messages,
      modality: modality,
      attachments: attachments,
      // The chat's project, so the agent answers with that folder open. Null for
      // a chat that belongs to no project (it falls back to the app's folder).
      workdir: workdir,
      // The project's house rules, prepended to the agent's first turn.
      instructions: instructions,
      // Lets the agent sender keep one live session per conversation and send
      // only the new turn (the API sender ignores it).
      conversationId: id,
      // A planning turn runs read-only and asks the agent to lay out a plan.
      planFirst: planTurn,
      // This chat's own permission level, not the app's — a turn dispatched
      // into a background chat must run under that chat's rules.
      approval: approval,
    );

    String? agentSessionId;
    _subs[id] = updates.listen(
      (update) {
        // The conversation may have been deleted mid-flight — drop the update
        // rather than resurrect it.
        final current = _find(id);
        if (current == null) return;
        switch (update) {
          case ChatSendGenerating(:final progress, :final status):
            state = state.withPhase(
              id,
              SendGenerating(progress: progress, status: status),
            );
          case ChatSendStreaming(:final text):
            if (firstToken == null && text.trim().isNotEmpty) {
              firstToken = clock.elapsed;
            }
            state = state.withPhase(id, SendStreaming(text));
          case ChatSendAgentSession(:final sessionId):
            agentSessionId = sessionId;
          case ChatSendSuccess(:final reply):
            final answered = current.copyWith(
              updatedAt: DateTime.now(),
              // Stamp the reply with the model that answered, so the transcript
              // says which one spoke even after switching models mid-chat.
              messages: [
                ...current.messages,
                reply.copyWith(
                  model: model,
                  took: clock.elapsed,
                  firstToken: firstToken,
                ),
              ],
            );
            // A planning turn's reply is a plan waiting on approval — light the
            // "approve & run" bar for this chat. Any other reply leaves it dark.
            // Does not steal focus: a reply landing in a background chat leaves
            // whatever the user is reading open.
            _commit(answered, phase: const SendIdle(), awaitingPlan: planTurn);
            _adoptAgentName(answered, agentSessionId);
            _announceTurn(answered, body: firstLinePreview(reply.text));
            _lastTurn[id] = (reply: reply.text, failure: null);
          case ChatSendFailure(:final error, :final partial):
            // Keep what the assistant produced before it failed — its streamed
            // prose, the plan it laid out — instead of wiping the turn to a bare
            // error line, which reads as "it did nothing". The error still
            // shows, with its retry / switch-agent affordance. Mirrors stop();
            // the streamed text is the fallback for a relay turn that carries no
            // structured partial of its own.
            final phase = state.phaseFor(id);
            final streamed = phase is SendStreaming ? phase.text.trim() : '';
            final kept =
                partial ??
                (streamed.isEmpty
                    ? null
                    : ChatMessage(role: ChatRole.assistant, text: streamed));
            if (kept == null) {
              state = state
                  .withPhase(id, const SendIdle())
                  .withError(id, error);
            } else {
              _commit(
                current.copyWith(
                  updatedAt: DateTime.now(),
                  messages: [
                    ...current.messages,
                    // The part-answer is stamped too: a turn that died after
                    // four minutes and one that died instantly are different
                    // problems.
                    kept.copyWith(
                      model: model,
                      took: clock.elapsed,
                      firstToken: firstToken,
                    ),
                  ],
                ),
                phase: const SendIdle(),
              );
              // _commit clears the error; set it after so the line still shows
              // above the kept reply.
              state = state.withError(id, error);
            }
            _announceTurn(current, body: "Couldn't finish: $error");
            _lastTurn[id] = (reply: null, failure: error);
        }
      },
      onDone: () => _finish(id),
      onError: (Object _) => _finish(id),
      cancelOnError: true,
    );
  }

  /// Tell the desktop that [conversation] is done, unless the user is already
  /// watching it happen.
  ///
  /// An agent turn can run for minutes, and the reason to leave the app during
  /// one is that it doesn't need watching — so a reply that lands in silence is
  /// a reply the user finds twenty minutes late. A turn that *failed* is
  /// announced on the same terms: they are otherwise still waiting on an answer
  /// that is never coming.
  ///
  /// [body] is already the one line to show (see [firstLinePreview]).
  void _announceTurn(Conversation conversation, {required String body}) {
    final worthIt = notificationIsWorthIt(
      appFocused: ref.read(windowFocusedProvider),
      userIsLookingAtIt: state.activeId == conversation.id,
    );
    if (!worthIt) return;
    unawaited(
      ref
          .read(desktopNotifierProvider)
          .show(
            DesktopNotification(
              title: conversation.title,
              body: body,
              opens: conversation.id,
            ),
          ),
    );
  }

  /// Let the agent name the chat, replacing the placeholder taken from the first
  /// message ("hi") with what the conversation turned out to be about.
  ///
  /// The agent names a session once, off its opening exchange, so this only runs
  /// on the first reply — a later turn (or reopening the chat weeks on) must not
  /// rename a conversation the user already knows by its name.
  void _adoptAgentName(Conversation conversation, String? sessionId) {
    if (sessionId == null || conversation.messages.length != 2) return;
    unawaited(_rename(conversation.id, sessionId));
  }

  /// Wait for the name, then swap it in — without re-sorting or stealing focus,
  /// since by now the user may well be reading a different chat.
  Future<void> _rename(String conversationId, String sessionId) async {
    final title = await ref.read(agentSessionTitleProvider).waitFor(sessionId);
    if (title == null || _disposed) return;

    // Re-read *after* the wait, not before: the name takes seconds to arrive,
    // and the user may have named the chat themselves in the meantime. Theirs
    // wins — this is the only thing standing between a hand-typed title and an
    // agent silently replacing it.
    final current = _find(conversationId);
    if (current == null || current.titleLocked || current.title == title) {
      return;
    }
    final renamed = current.copyWith(title: title);
    _saveAndReplace(renamed);
  }

  /// Who answers this turn: the agent for plain text, the grid's chat API for
  /// anything with a picture in it (and on a computer with no agent installed).
  ChatSender _senderFor(
    PlaygroundModality modality,
    List<MediaAttachment> attachments,
  ) {
    final viaAgent = agentAnswersTurn(
      modality: modality,
      hasAttachments: attachments.isNotEmpty,
      agentInstalled: ref.read(anyAgentInstalledProvider),
    );
    return viaAgent
        ? ref.read(chatAgentSenderProvider)
        : ref.read(chatSenderProvider);
  }

  /// Stop the **open** chat's in-flight reply, keeping whatever the assistant had
  /// already said. A reply streaming in another chat is left running.
  ///
  /// The user's turn is persisted up front, but a half-written answer lives only
  /// in [SendStreaming] — dropping it would wipe text the user is reading, and
  /// they usually stop *because* they've read enough of it. Nothing streamed yet
  /// (the agent still thinking) means there's nothing to keep.
  void stop() {
    final id = state.activeId;
    if (id == null || !state.sendingFor(id)) return;
    final phase = state.phaseFor(id);
    _cancel(id);

    final partial = phase is SendStreaming ? phase.text.trim() : '';
    final current = state.active;
    if (partial.isEmpty || current == null) {
      state = state.withPhase(id, const SendIdle());
      return;
    }
    _commit(
      current.copyWith(
        updatedAt: DateTime.now(),
        messages: [
          ...current.messages,
          ChatMessage(role: ChatRole.assistant, text: partial),
        ],
      ),
      phase: const SendIdle(),
    );
  }
}
