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

    // Something the user actually sent — typed now, or typed behind the last
    // turn — is a fresh start for the carry-on budget (issue #28): the count
    // guards one instruction running away, not a conversation. A turn the app
    // sends on their behalf ([continuing]) is what the budget is *for*, so it
    // leaves the count alone.
    if (!continuing) state = state.withCarriedOn(target.id, 0);

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
    // approving a plan, carrying on after a turn ran out of steps. Each
    // continues a session that agent alone holds, and each is sent by the app
    // rather than typed, so under Auto they would be classified afresh — and a
    // plan handed to a second agent is a plan it never wrote.
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

    return _startCommittedTurn(
      conversation: conversation,
      network: network,
      effectiveModel: effectiveModel,
      modality: modality,
      attachments: attachments,
      planTurn: planTurn,
      approval: approval,
      viaAgent: viaAgent,
      autoChosen: autoChosen,
      continuedAgent: continuedAgent,
      question: text,
    );
  }

  /// Repeat the open chat's failed turn with the model currently selected.
  ///
  /// The original user turn is already persisted, including its pictures and
  /// files. Retry sends that same turn again instead of appending a duplicate;
  /// any partial assistant answer from the failed attempt is replaced.
  Future<void> retry({
    required NetworkCredential network,
    required String model,
    PlaygroundModality modality = PlaygroundModality.text,
  }) async {
    final active = state.active;
    if (active == null || state.sending || state.error == null) return;
    final retryable = _retryableTurns[active.id];
    if (retryable == null || retryable.messageCount > active.messages.length) {
      return;
    }
    final messages = active.messages.take(retryable.messageCount).toList();
    if (messages.isEmpty || messages.last.role != ChatRole.user) return;

    final conversation = active.copyWith(
      model: model,
      updatedAt: DateTime.now(),
      messages: messages,
    );
    final autoChosen = ref.read(
      isAutoAgentChosenForProjectProvider(conversation.projectId),
    );
    final effectiveModel = (autoChosen && ref.read(gridServesAutoModelProvider))
        ? kAutoModelId
        : model;
    final viaAgent = agentAnswersTurn(
      modality: modality,
      hasAttachments: retryable.attachments.isNotEmpty,
      agentInstalled: ref.read(anyAgentInstalledProvider),
    );
    final approval = approvalFor(
      conversation,
      ref.read(chatPrefsProvider).approval,
    );

    _commit(conversation, phase: const SendBusy());
    return _startCommittedTurn(
      conversation: conversation,
      network: network,
      effectiveModel: effectiveModel,
      modality: modality,
      attachments: retryable.attachments,
      planTurn: retryable.planTurn && viaAgent,
      approval: approval,
      viaAgent: viaAgent,
      autoChosen: autoChosen,
      continuedAgent: retryable.continuedAgent,
      question: messages.last.text,
    );
  }

  /// Start a turn whose user message is already present in [conversation].
  ///
  /// Both a new Send and Retry land here, so agent routing, project queues and
  /// cancellation behave identically for the two paths.
  Future<void> _startCommittedTurn({
    required Conversation conversation,
    required NetworkCredential network,
    required String effectiveModel,
    required PlaygroundModality modality,
    required List<MediaAttachment> attachments,
    required bool planTurn,
    required AgentApprovalMode approval,
    required bool viaAgent,
    required bool autoChosen,
    required AgentTool? continuedAgent,
    required String question,
  }) async {
    final id = conversation.id;
    _retryableTurns[id] = _RetryableTurn(
      messageCount: conversation.messages.length,
      attachments: List.unmodifiable(attachments),
      planTurn: planTurn,
      continuedAgent: continuedAgent,
    );
    // Empty this chat's live feed the moment the turn is committed, not when its
    // sender finally starts. The working bubble is on screen from here, and
    // everything between here and the sender — the grid being asked which
    // assistant answers, for one — is time it would spend
    // showing the *previous* turn's commands under the new question. The sender
    // resets again as it starts, because it is reached from the Playground too;
    // this is the earlier of the two, not a second copy of the rule.
    // Every turn, not only an agent's. A turn the grid answers directly (a
    // picture, a computer with no agent) writes nothing to this feed — so
    // leaving the last turn's steps standing meant a relay turn the user stopped
    // half-way was committed carrying the *previous* turn's commands, which it
    // had not run.
    ref.read(agentRunsProvider.notifier).reset(id);
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
            question: question,
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

    // Every turn goes out when it is sent, agent or not, project or not.
    //
    // Agent turns used to take turns within a project, on the grounds that two
    // agents in one folder edit the same files. What that cost was worse than
    // what it prevented: a second question about the same project sat behind a
    // twenty-minute turn saying "finishing another chat in this project…", with
    // no way to run the two at once and no way to see why waiting was the app's
    // idea rather than the machine's.
    //
    // TODO(BE): the clash it was guarding is real and is now the user's to
    // avoid — two agents told to edit the same file will both edit it, and the
    // one that writes last wins. Worth revisiting as something the app can
    // *detect* (the changes each turn records are already tracked per chat)
    // rather than something it forbids in advance.
    dispatch();
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
    // Time the turn from here, not from `send`: a turn can wait behind a queued
    // one, and "Working now" would otherwise report the wait as work.
    state = state.withTurnStarted(id, DateTime.now());
    // Say this chat has an agent running, and which one — what the sidebar
    // marks, what "Working now" names, and what `stop` releases — and mark where
    // this turn's file changes begin, so "what did it just do?" answers for this
    // turn and not the chat's whole history.
    if (viaAgent) {
      state = state.copyWith(
        runningAgents: {...state.runningAgents, id: agent.id},
      );
      ref.read(agentChangesProvider.notifier).beginTurn(id);
    }

    // The folder the agent will actually run in — the chat's project, or the
    // app's own workspace when it has none. Resolved here as well as inside the
    // sender because a resume point is only adopted when its folder matches the
    // turn's, and a point written down as "no folder" would never match the
    // workspace path the sender falls back to. Same rule, same answer.
    final root = workdir ?? ref.read(agentWorkspaceDirProvider).path;

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

    // Which models actually answer this turn — the grid is the only party that
    // knows, since the agent makes its own relay calls and only ever knows the
    // name it was handed (`auto`, or a tier alias). Watched from here so the
    // working bubble can show it changing while a long task runs.
    ref.read(turnModelUsageProvider.notifier).begin(id, network);

    // Who answered, with what, where, and how long it took — the footer's four
    // facts, stamped onto whatever the turn produced (a whole reply, or the
    // part-answer a failure left behind).
    ChatMessage stamp(ChatMessage reply) => reply.copyWith(
      // And how the turn went, so the finished transcript keeps the order the
      // user watched it in. Here rather than in each sender: this is the one
      // place every landing goes through — the answer, the part-answer a failure
      // left, the half-turn Stop kept — and four copies of it would be four
      // chances for one of them to drop the steps.
      parts: _timelineOf(id, reply.text, viaAgent: viaAgent),
      // Only when the agent actually answered: a picture, or a computer with no
      // agent installed, goes straight to the grid's chat API.
      agent: viaAgent ? agent.id : null,
      model: model,
      node: node,
      // What has been polled so far. The final reading lands a moment later and
      // patches this message — see `_settleModelShares`.
      modelShares: ref.read(turnModelUsageProvider)[id] ?? const [],
      took: clock.elapsed,
      firstToken: firstToken,
    );

    final updates = _senderFor(viaAgent, agent).send(
      network: network,
      model: model,
      // Not the whole transcript when it has been compacted: the summary
      // stands in for what it covers (see [historyForTurn]).
      history: historyForTurn(conversation.messages, conversation.compaction),
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
      // The session this chat was last having, so quitting the app — or
      // importing the chat from the tool that opened it — doesn't cost the
      // agent everything it had worked out. The sender ignores a point that
      // isn't its own agent's, in its own folder.
      resume: conversation.resume,
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
            final messages = [...current.messages, stamp(reply)];
            final answered = current.copyWith(
              updatedAt: DateTime.now(),
              // Stamp the reply with who and what answered, so the transcript
              // still says so even after switching agent or model mid-chat.
              messages: messages,
              // Where this chat can pick up from next time. Written on every
              // successful agent turn — the session id and how much of the
              // transcript it holds both move — so the answer survives a quit.
              // Null leaves whatever was already there: a relay turn (a
              // picture) has no session of its own and must not erase the one
              // the agent is still holding.
              resume: _resumePointFor(
                viaAgent: viaAgent,
                agent: agent,
                sessionId: agentSessionId,
                root: root,
                seen: messages.length,
              ),
            );
            // The last reading of what served this turn. Fired rather than
            // awaited: a caption is not worth holding the answer back for, so
            // the bubble shows what was polled and this corrects it a moment
            // later.
            unawaited(_settleModelShares(id, network, messages.length - 1));
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
            _retryableTurns.remove(id);
            _nameConversation(answered, agentSessionId);
            // Silent when the app is about to carry this turn on itself: the
            // reply is a summary the agent was told to write mid-job, and a
            // notification per budget would tell a user who stepped away that
            // their task stopped three times when it is still running.
            if (!willCarryOn(id)) {
              _announceTurn(answered, body: firstLinePreview(reply.text));
            }
            _lastTurn[id] = (
              reply: reply.text,
              failure: null,
              // Did it *do* anything, or only talk? The stamped timeline is the
              // record of the steps it ran.
              ranSteps: messages.last.parts.isNotEmpty,
            );
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
            _lastTurn[id] = (reply: null, failure: error, ranSteps: false);
        }
      },
      onDone: () => _finish(id),
      onError: (Object _) => _finish(id),
      cancelOnError: true,
    );
  }

  /// How the turn in chat [id] went — its passages and steps in order, with
  /// [text] closed off as the last thing it said.
  ///
  /// Empty for a turn no agent answered, and for one that ran no steps at all:
  /// there the timeline would be the answer and nothing else, which is what the
  /// message's own text already says. Nothing to store, nothing to draw
  /// differently, and a chat file that stays exactly as it was.
  List<TurnPart> _timelineOf(String id, String text, {required bool viaAgent}) {
    if (!viaAgent) return const [];
    // Asked before the closing words are placed, so a turn with nothing to
    // interleave leaves the run untouched rather than filing prose against a
    // chat whose feed nobody will read.
    if (!hasSteps(ref.read(agentRunProvider(id)).parts)) return const [];
    // The closing words haven't been placed yet — only a step closes a passage,
    // and after the last one the agent went on talking.
    ref.read(agentRunsProvider.notifier).say(id, text);
    // Nothing may be left spinning in a turn that has ended (see
    // [settledParts]) — the live feed is gone by the time this is read.
    return settledParts(ref.read(agentRunProvider(id)).parts);
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

  /// Where this chat picks up next time, or null to leave whatever is already
  /// written down.
  ///
  /// Null rather than a cleared point in three cases, and each would be a
  /// regression if it wiped one: a turn the grid's chat API answered (a
  /// picture) has no session; an agent that reported no session id has nothing
  /// to record; and Hermes's id names a live process that will be gone by the
  /// next launch (see [AgentTool.resumesBySessionId]).
  AgentResumePoint? _resumePointFor({
    required bool viaAgent,
    required AgentTool agent,
    required String? sessionId,
    required String root,
    required int seen,
  }) {
    if (!viaAgent || sessionId == null) return null;
    if (!agent.resumesBySessionId) return null;
    return AgentResumePoint(
      agent: agent.id,
      sessionId: sessionId,
      // Everything in the chat now, this reply included: the agent has just
      // been handed the turn and has answered it, so it holds all of it.
      seen: seen,
      workdir: root,
    );
  }

  /// Have the chat named for what it turned out to be about, replacing the line
  /// taken from the first message ("hi").
  ///
  /// Runs on every turn until a model has actually written a name, not only on
  /// the first: nothing here is guaranteed to answer — no agent name, no model
  /// reachable this minute — and one attempt meant a chat that missed it kept
  /// its first line for good. Once [Conversation.titleFromModel] is set the chat
  /// is left alone, so a conversation the user already knows by its name is
  /// never renamed under them; a chat they named themselves is never touched at
  /// all.
  void _nameConversation(Conversation conversation, String? sessionId) {
    if (conversation.titleLocked || conversation.titleFromModel) return;
    // Nothing to name it from until something has been asked and answered.
    if (conversation.messages.length < 2) return;
    // An attempt takes seconds and a chat can be several turns further on by
    // the time it lands. Without this, each of those turns starts its own.
    if (!_naming.add(conversation.id)) return;
    unawaited(
      _rename(
        conversation.id,
        sessionId,
        firstExchange: conversation.messages.length == 2,
      ),
    );
  }

  /// Wait for the name, then swap it in — without re-sorting or stealing focus,
  /// since by now the user may well be reading a different chat.
  Future<void> _rename(
    String conversationId,
    String? sessionId, {
    required bool firstExchange,
  }) async {
    try {
      final title = await _nameFor(
        conversationId,
        sessionId,
        firstExchange: firstExchange,
      );
      if (title == null || _disposed) return;

      // Re-read *after* the wait, not before: the name takes seconds to arrive,
      // and the user may have named the chat themselves in the meantime. Theirs
      // wins — this is the only thing standing between a hand-typed title and a
      // model silently replacing it.
      final current = _find(conversationId);
      if (current == null || current.titleLocked) return;
      // Written even when the name matches the one already there, because the
      // flag is the point: it is what stops the next turn asking again.
      _saveAndReplace(current.copyWith(title: title, titleFromModel: true));
    } finally {
      _naming.remove(conversationId);
    }
  }

  /// What to call the chat, asked for in the order of who knows most about it
  /// for the least: the agent that ran the turn already named its own session
  /// off the same exchange, so asking it costs a local read; every other chat —
  /// a turn the grid's chat API answered, a computer with no agent installed,
  /// an agent that named nothing — is worth one small completion of its own.
  ///
  /// Null when neither could answer, and the name derived from the first message
  /// ([chatTitleFromLine]) stands. Nothing here ever reports a failure: nobody
  /// asked for a name, so nobody may be interrupted about one.
  Future<String?> _nameFor(
    String conversationId,
    String? sessionId, {
    required bool firstExchange,
  }) async {
    // Only on the opening exchange: an agent names its session once, off that
    // exchange, so asking on turn five is twelve seconds of polling for a name
    // that was never going to be written.
    if (firstExchange && sessionId != null) {
      final named = await ref
          .read(agentSessionTitleProvider)
          .waitFor(sessionId);
      if (named != null) return named;
    }
    if (_disposed) return null;

    // Re-read rather than closing over the conversation: the wait above runs for
    // seconds, and what is asked about has to be the transcript as it is now.
    final chat = _find(conversationId);
    if (chat == null || chat.titleLocked) return null;
    return ref.read(chatTitleWriterProvider).write(chat.messages);
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

  /// Stop the **open** chat's in-flight reply. A reply streaming in another chat
  /// is left running — see [stopChat], which this is the composer's shorthand
  /// for.
  void stop() {
    final id = state.activeId;
    if (id != null) stopChat(id);
  }

  /// Stop every chat that is answering — "Working now"'s stop-all.
  ///
  /// Over a copy of the keys, because each [stopChat] writes state: iterating the
  /// live map would be modifying it while walking it.
  void stopAll() {
    for (final id in state.phases.keys.toList()) {
      stopChat(id);
    }
  }

  /// Stop the chat with [id]'s in-flight reply, keeping whatever the assistant
  /// had already said.
  ///
  /// The user's turn is persisted up front, but a half-written answer lives only
  /// in [SendStreaming] — dropping it would wipe text the user is reading, and
  /// they usually stop *because* they've read enough of it. Nothing streamed yet
  /// (the agent still thinking) means there's nothing to keep.
  ///
  /// Takes the chat by id rather than acting on the open one, because it is
  /// reached from "Working now" as well as the composer: a turn several projects
  /// away is exactly the one a user stops from there, and it must not bring that
  /// chat to the front to do it (see [_commit], which leaves the open chat put).
  void stopChat(String id) {
    if (!state.sendingFor(id)) return;
    final phase = state.phaseFor(id);
    _cancel(id);

    final partial = phase is SendStreaming ? phase.text.trim() : '';
    final current = _find(id);
    if (partial.isEmpty || current == null) {
      state = state.withPhase(id, const SendIdle());
      return;
    }
    _commit(
      current.copyWith(
        updatedAt: DateTime.now(),
        messages: [
          ...current.messages,
          ChatMessage(
            role: ChatRole.assistant,
            text: partial,
            // The steps it ran before it was stopped are half the account of
            // what happened — a turn cut off after six commands and one cut off
            // before it did anything are different turns, and the transcript is
            // all that is left to say which this was.
            parts: _timelineOf(id, partial, viaAgent: true),
          ),
        ],
      ),
      phase: const SendIdle(),
    );
  }

  /// Take the final reading of which models served [chat]'s turn and write it
  /// onto the message at [index].
  ///
  /// Separate from the stamp because the stamp cannot wait: the reply is already
  /// on screen, and the last poll may still be a few seconds behind the turn's
  /// closing requests. A read that fails, a grid that answers 404 (its master
  /// predating the endpoint), or a chat deleted meanwhile all leave the stamped
  /// value alone — this only ever corrects upward, never blanks.
  Future<void> _settleModelShares(
    String chat,
    NetworkCredential network,
    int index,
  ) async {
    final shares = await ref
        .read(turnModelUsageProvider.notifier)
        .end(chat, network);
    if (shares.isEmpty) return;
    final current = _find(chat);
    if (current == null || index < 0 || index >= current.messages.length) {
      return;
    }
    final messages = [...current.messages];
    messages[index] = messages[index].copyWith(modelShares: shares);
    // Whatever the chat is doing now, not an assumed idle: the user may already
    // have asked the next question, and a correction to the last turn's caption
    // must not knock that turn's "answering" state off the screen.
    _commit(current.copyWith(messages: messages), phase: state.phaseFor(chat));
  }
}
