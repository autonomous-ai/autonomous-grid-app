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
    List<ChatContext> contexts = const [],
    bool? planFirst,
    String? into,
    bool continuing = false,
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
          contexts: List.unmodifiable(contexts),
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

    // Auto agent: the grid picks which installed assistant answers, and it runs
    // on the grid's auto model — the one model every agent can use, so the
    // routed one never dead-ends on a pair the composer left showing. The agent
    // itself is chosen below, once the message is on screen. [effectiveModel] is
    // what actually goes on the wire; the conversation keeps the model the user
    // picked, so leaving Auto doesn't leave `auto` behind in their composer.
    final autoChosen = ref.read(
      isAutoAgentChosenForProjectProvider(target.projectId),
    );
    // Only swap to `auto` on a grid that actually serves it — a grid with no
    // auto-routing would refuse `auto` outright. Where it isn't served the
    // composer's own model stands, and the candidate pool below is narrowed to
    // the agents that can answer with it.
    final effectiveModel = (autoChosen && ref.read(gridServesAutoModelProvider))
        ? kAutoModelId
        : model;

    // Plain text goes through the agent (it can use tools and keeps the
    // conversation's context); pictures — generating one, or a turn that carries
    // attachments — go straight to the grid's chat API, which is the only one
    // that can see or make them. Decided here, before anything is committed,
    // because it also decides whether the turn is worth routing at all.
    final viaAgent = agentAnswersTurn(
      modality: modality,
      hasAttachments: attachments.isNotEmpty,
      agentInstalled: ref.read(anyAgentInstalledProvider),
    );

    // What this chat lets the agent do — its own choice when it has one, else
    // the app's standing one. Read once here so the turn runs under the mode
    // that was on screen when Send was pressed, even if the user switches chats
    // (or modes) while it streams.
    final approval = approvalFor(target, ref.read(chatPrefsProvider).approval);

    // Plan mode's planning turn: only when the composer is set to Plan (unless
    // the caller forced it — the approve path forces it off) and the agent is
    // the one answering, since a relay/media turn has no plan/act split.
    final planTurn =
        (planFirst ?? approval == AgentApprovalMode.plan) && viaAgent;

    // A follow-up that has to land on the **same** agent as the turn before it:
    // approving a plan, carrying on after a turn ran out of steps, the next step
    // of a goal. Each continues a session that agent alone holds, and each is
    // sent by the app rather than typed, so under Auto they would be classified
    // afresh — and a plan handed to a second agent is a plan it never wrote.
    //
    // Only under Auto: where the user has named an agent, their pick still
    // stands, because changing it is something they did on purpose and the
    // handover bar says so. A message they typed themselves is a fresh question
    // and is routed like any other.
    final continuedAgent = (continuing && autoChosen)
        ? _agentOfLastReply(target)
        : null;

    // Append the user turn and persist it up front, so an interrupted reply
    // never loses what the user typed. A new compose becomes a real, saved
    // conversation here. Attached images (vision) are saved to disk so they
    // render, persist and can be re-encoded into the request.
    final userTurn = await buildUserTurn(
      text: text,
      attachments: attachments,
      files: files,
      contexts: contexts,
      outputsDir: ref.read(mediaOutputsDirProvider),
    );
    // The chat remembers the model the *user* chose, never the one Auto swapped
    // in: the composer is restored from it, so writing `auto` here would replace
    // their pick with the router's — and leave it there after they had gone back
    // to a named agent, with nothing to say what had changed it.
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
    // Empty this chat's live feed the moment the turn is committed, not when its
    // sender finally starts. The working bubble is on screen from here, and
    // everything between here and the sender — the grid being asked which
    // assistant answers, a wait for the project's lane — is time it would spend
    // showing the *previous* turn's commands under the new question. The sender
    // resets again as it starts, because it is reached from the Playground too;
    // this is the earlier of the two, not a second copy of the rule.
    if (viaAgent) ref.read(agentRunsProvider.notifier).reset(id);
    final done = _dones[id] = Completer<void>();
    final project = ref.read(projectByIdProvider(conversation.projectId));
    // Who answers this turn, read here for the same reason [approval] is: the
    // agent belongs to the chat's *project*, and a turn can go out (or wait in
    // the agent queue) long after the user has moved to a project that runs a
    // different one.
    //
    // Under Auto, the pick is the grid's: it reads the question and each
    // installed agent's strengths and names one. Done here, after the user turn
    // is on screen (SendBusy shows a spinner), so the ~1s classification reads
    // as the turn starting rather than a lag before the box clears. Every branch
    // returns a usable agent — one candidate, an unreachable grid, an unreadable
    // reply all fall back — so the reply footer still names who actually
    // answered while the picker keeps saying "Auto".
    //
    // Only for a turn an agent will answer: a picture goes to the grid's chat
    // API whoever is picked, so routing it would spend a relay call and up to
    // the router's whole timeout on an answer thrown away.
    AgentTool agent =
        continuedAgent ??
        ref.read(chatAgentForProjectProvider(conversation.projectId));
    if (autoChosen && viaAgent && continuedAgent == null) {
      agent = await ref
          .read(autoAgentRouterProvider)
          .route(
            question: text,
            candidates: ref.read(autoAgentCandidatesProvider(effectiveModel)),
          );
      // Routing is the one await between committing the turn and sending it, and
      // seconds long. Stop or Delete during it settles the send — [_cancel] drops
      // this completer — and dispatching anyway would start an agent the user
      // just stopped, in a chat they may have deleted.
      if (!identical(_dones[id], done)) return;
    }

    void dispatch() => _dispatch(
      conversation: conversation,
      network: network,
      model: effectiveModel,
      modality: modality,
      attachments: attachments,
      workdir: project?.path,
      // Both the project's house rules and the facts it's been asked to
      // remember — one standing brief the agent reads on its first turn.
      instructions: project == null ? null : projectStandingBrief(project),
      planTurn: planTurn,
      approval: approval,
      viaAgent: viaAgent,
      agent: agent,
      done: done,
    );

    // Agent turns take turns **within a project** (see [_agentQueues]): two
    // agents in one folder would edit the same files. Anywhere else — another
    // project, or no project at all — the turn goes straight out, concurrently,
    // as a relay/media turn always has.
    final lane = conversation.projectId;
    if (viaAgent && lane != null && _laneBusy(lane, except: id)) {
      (_agentQueues[lane] ??= []).add((id: id, dispatch: dispatch));
      // Said out loud in the state, because the transcript's "finishing another
      // chat in this project…" is only true here — see [laneQueuedIds].
      state = state.withLaneQueued(id, true);
    } else {
      dispatch();
    }
    return done.future;
  }

  /// The agent that wrote [chat]'s most recent reply, or null when the last one
  /// came from the grid itself (no agent stamp) or from an agent this build no
  /// longer ships.
  ///
  /// Read off the transcript rather than remembered in a field: the stamp is
  /// already persisted with the reply, so approving a plan still continues the
  /// right agent after a restart, and a chat that has never had an agent reply
  /// falls back to being routed like any other.
  AgentTool? _agentOfLastReply(Conversation chat) {
    for (final message in chat.messages.reversed) {
      if (message.role != ChatRole.assistant) continue;
      return agentToolById(message.agent);
    }
    return null;
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
    required AgentTool agent,
    required Completer<void> done,
  }) {
    final id = conversation.id;
    // Whatever it was waiting for, it isn't waiting now.
    if (state.laneQueuedIn(id)) state = state.withLaneQueued(id, false);
    // Take this project's lane — released on finish/stop, which then starts the
    // next turn waiting in it — and mark where this turn's file changes begin,
    // so "what did it just do?" answers for this turn and not the chat's whole
    // history.
    if (viaAgent) {
      state = state.copyWith(runningAgentIds: {...state.runningAgentIds, id});
      ref.read(agentChangesProvider.notifier).beginTurn(id);
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

    // Which machine on the grid is behind this model, read as the turn goes out
    // rather than when the bubble is drawn: nodes come and go, and a transcript
    // re-read next week must still say who answered *then*. Null whenever that
    // can't be told — see [nodeServingModel].
    final node = nodeServingModel(
      ref.read(gridOverviewSnapshot)?.nodes ?? const <OverviewNode>[],
      model,
    );

    // Who answered, with what, where, and how long it took — the footer's four
    // facts, stamped onto whatever the turn produced (a whole reply, or the
    // part-answer a failure left behind).
    ChatMessage stamp(ChatMessage reply) => reply.copyWith(
      // Only when the agent actually answered: a picture, or a computer with no
      // agent installed, goes straight to the grid's chat API.
      agent: viaAgent ? agent.id : null,
      model: model,
      node: node,
      took: clock.elapsed,
      firstToken: firstToken,
    );

    final updates = _senderFor(viaAgent, agent).send(
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
          case ChatSendSuccess(:final reply, :final outOfSteps):
            final answered = current.copyWith(
              updatedAt: DateTime.now(),
              // Stamp the reply with who and what answered, so the transcript
              // still says so even after switching agent or model mid-chat.
              messages: [...current.messages, stamp(reply)],
            );
            // A planning turn's reply is a plan waiting on approval — light the
            // "approve & run" bar for this chat. Any other reply leaves it dark.
            // Does not steal focus: a reply landing in a background chat leaves
            // whatever the user is reading open.
            // An agent that ran out of tool calls mid-plan lights the "carry on"
            // bar instead of leaving the user to wonder why it halted three
            // steps in — the reply above is a summary it was told to write.
            _commit(
              answered,
              phase: const SendIdle(),
              awaitingPlan: planTurn,
              outOfSteps: outOfSteps,
            );
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
                  // The part-answer is stamped too: a turn that died after four
                  // minutes and one that died instantly are different problems.
                  messages: [...current.messages, stamp(kept)],
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

  /// Who answers this turn: [agent] for plain text ([viaAgent]), the grid's chat
  /// API for anything with a picture in it (and on a computer with no agent
  /// installed).
  ///
  /// Both facts are decided by the caller and passed in rather than re-derived
  /// here: the turn has to be sent by the agent its own chat resolved at Send,
  /// which an agent turn waiting in the queue can outlive.
  ChatSender _senderFor(bool viaAgent, AgentTool agent) => viaAgent
      ? ref.read(agentChatSenderProvider(agent))
      : ref.read(chatSenderProvider);

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
