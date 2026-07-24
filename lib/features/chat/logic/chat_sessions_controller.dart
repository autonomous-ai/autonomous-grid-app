import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../agent/logic/agent_permissions.dart';
import '../../agent/logic/agent_routing.dart';
import '../../agent/logic/agent_session_title.dart';
import '../../agents/logic/active_chat_agent.dart';
import '../../agents/logic/agent_status.dart';
import '../../auth/logic/session_controller.dart';
import '../../playground/logic/chat_message.dart';
import '../../playground/logic/chat_sender.dart';
import '../../playground/logic/media_outputs.dart';
import '../../playground/logic/playground_request.dart';
import '../../projects/logic/project.dart';
import 'chat_store.dart';
import 'conversation.dart';

export '../../playground/logic/chat_message.dart'
    show
        ChatRole,
        ChatMessage,
        ChatMedia,
        SendPhase,
        SendBusy,
        SendGenerating,
        SendStreaming;

/// The Chat tab's whole state: every saved conversation (newest first), which
/// one is open, and the in-flight send [phase] / [error]. A null [activeId]
/// means the user is composing a brand-new chat that isn't saved yet — it gets
/// persisted the moment they send the first message.
class ChatSessionsState {
  const ChatSessionsState({
    this.conversations = const [],
    this.activeId,
    this.phase = const SendIdle(),
    this.error,
    this.awaitingPlan = false,
  });

  final List<Conversation> conversations;
  final String? activeId;
  final SendPhase phase;
  final String? error;

  /// True when the last turn was Plan mode's planning turn and its plan is
  /// waiting on the user: the chat shows an "approve & run" bar. Cleared the
  /// moment anything else happens (a new send, approving, dismissing, switching
  /// chat) — it's live interaction state, not saved with the conversation.
  final bool awaitingPlan;

  /// The open conversation, or null while composing a new one.
  Conversation? get active {
    final id = activeId;
    if (id == null) return null;
    for (final c in conversations) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// The chats that haven't been archived — what the sidebar, the tray menu and
  /// ⌘K all list. [conversations] stays the whole set so the Archived screen
  /// has something to read; anything showing the user their *working* history
  /// wants this instead.
  List<Conversation> get live => [
    for (final c in conversations)
      if (!c.isArchived) c,
  ];

  /// The archived chats, most recently archived first — the Archived screen's
  /// source list, before its own search/sort/filter narrow it further.
  List<Conversation> get archived => [
    for (final c in conversations)
      if (c.isArchived) c,
  ]..sort((a, b) => b.archivedAt!.compareTo(a.archivedAt!));

  /// True while a request is in flight — the composer disables on this.
  bool get sending => phase is! SendIdle;
}

/// Drives the persistent Chat tab. Loads saved conversations on start, and on
/// each send appends the turn to the open conversation and writes it to disk
/// via [ChatStore]. The actual dispatch is delegated to the shared [ChatSender]
/// so text/image/video routing and error copy match the Playground exactly.
final chatSessionsProvider =
    NotifierProvider<ChatSessionsController, ChatSessionsState>(
      ChatSessionsController.new,
    );

class ChatSessionsController extends Notifier<ChatSessionsState> {
  StreamSubscription<ChatSendUpdate>? _sub;
  Completer<void>? _done;

  /// The project a not-yet-saved chat belongs to. A new chat isn't persisted
  /// until its first message, so the choice has to be held here until then.
  String? _draftProjectId;

  /// Naming a chat outlives the send it started in (the agent writes the name
  /// seconds later), so it has to know when there's no longer a state to write.
  bool _disposed = false;

  @override
  ChatSessionsState build() {
    ref.onDispose(() {
      _disposed = true;
      _cancel();
    });
    final conversations = ref.read(chatStoreProvider).loadAll();
    // Opens on the newest *live* chat: `conversations` holds the archived ones
    // too, and landing the user in one they filed away — in a transcript the
    // sidebar doesn't even list — would look like the app lost their history.
    final opening = [
      for (final c in conversations)
        if (!c.isArchived) c,
    ];
    return ChatSessionsState(
      conversations: conversations,
      activeId: opening.isEmpty ? null : opening.first.id,
    );
  }

  ChatStore get _store => ref.read(chatStoreProvider);

  /// The project a not-yet-saved chat is being composed in, so the `@`-mention
  /// menu can list that folder before the chat is persisted.
  String? get draftProjectId => _draftProjectId;

  /// Open a fresh, empty compose, optionally inside [projectId] — the folder the
  /// assistant may read while answering it. Not persisted until the first
  /// message, so clicking "New chat" repeatedly never litters the history with
  /// blanks.
  void newChat({String? projectId}) {
    if (state.sending) return;
    _draftProjectId = projectId;
    state = ChatSessionsState(conversations: state.conversations);
  }

  /// Switch to a saved conversation. Ignored mid-send so a reply can't land in
  /// the wrong transcript.
  void select(String id) {
    if (state.sending || id == state.activeId) return;
    state = ChatSessionsState(conversations: state.conversations, activeId: id);
  }

  /// Remember the model chosen for the open conversation, so leaving the chat and
  /// coming back — or reopening it later — restores *that* choice, not the grid's
  /// default. A no-op for a not-yet-saved compose (its model rides the first
  /// send) and while a reply is streaming. Leaves `updatedAt` untouched, so
  /// picking a model never re-sorts the sidebar.
  void setActiveModel(String model) {
    if (state.sending || model.isEmpty) return;
    final active = state.active;
    if (active == null || active.model == model) return;
    final updated = active.copyWith(model: model);
    _store.save(updated);
    state = ChatSessionsState(
      conversations: [
        for (final c in state.conversations)
          if (c.id == updated.id) updated else c,
      ],
      activeId: state.activeId,
      phase: state.phase,
      error: state.error,
    );
  }

  /// Give a conversation the name the user typed, replacing whatever was
  /// derived from its first message.
  ///
  /// [updatedAt] is deliberately left alone: it orders the sidebar by when a
  /// chat was last *talked in*, and retitling one is not talking in it — bumping
  /// it would jump an old chat to the top for a cosmetic edit.
  void renameConversation(String id, String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    final chat = _find(id);
    if (chat == null || chat.title == trimmed) return;
    // Locked from here on: the agent's own name for this chat can still be
    // seconds out, and it must not overwrite the one the user just typed.
    final renamed = chat.copyWith(title: trimmed, titleLocked: true);
    _store.save(renamed);
    state = ChatSessionsState(
      conversations: [
        for (final c in state.conversations)
          if (c.id == renamed.id) renamed else c,
      ],
      activeId: state.activeId,
      phase: state.phase,
      error: state.error,
    );
  }

  /// Delete a conversation from disk and state, falling back to the newest
  /// remaining one (or a new compose) when the open one is removed.
  void deleteConversation(String id) {
    _store.delete(id);
    final remaining = [
      for (final c in state.conversations)
        if (c.id != id) c,
    ];
    final activeId = state.activeId == id
        ? (remaining.isEmpty ? null : remaining.first.id)
        : state.activeId;
    state = ChatSessionsState(
      conversations: remaining,
      activeId: activeId,
      phase: state.phase,
      error: state.error,
    );
  }

  /// Archive a conversation: hide it from the sidebar, the tray and ⌘K without
  /// touching a single message in it. The transcript stays on disk and comes
  /// back whole from [unarchiveConversation].
  ///
  /// Ignored mid-send, for the same reason [select] is: filing away the chat a
  /// reply is streaming into would leave that reply landing in a transcript the
  /// user can no longer see.
  void archiveConversation(String id) {
    if (state.sending && state.activeId == id) return;
    final chat = _find(id);
    if (chat == null || chat.isArchived) return;
    final archived = chat.copyWith(archivedAt: DateTime.now());
    _store.save(archived);
    _replace(archived, activeId: _activeIdAfterHiding(id));
  }

  /// Put an archived conversation back: it returns to the sidebar in its old
  /// place (ordered by [Conversation.updatedAt] — archiving never touched it,
  /// so it lands back where the user last left it, not at the top).
  void unarchiveConversation(String id) {
    final chat = _find(id);
    if (chat == null || !chat.isArchived) return;
    final restored = chat.copyWith(clearArchivedAt: true);
    _store.save(restored);
    _replace(restored, activeId: state.activeId);
  }

  /// Delete every archived conversation — the Archived screen's "Delete all".
  /// Live chats are left strictly alone, so the button can never reach the
  /// history the user is still working in.
  ///
  /// Takes an optional [ids] subset for "Delete all in project", which is the
  /// same operation scoped to one group.
  void deleteArchivedConversations({Set<String>? ids}) {
    final doomed = [
      for (final c in state.conversations)
        if (c.isArchived && (ids == null || ids.contains(c.id))) c.id,
    ];
    if (doomed.isEmpty) return;
    for (final id in doomed) {
      _store.delete(id);
    }
    final gone = doomed.toSet();
    final remaining = [
      for (final c in state.conversations)
        if (!gone.contains(c.id)) c,
    ];
    // The open chat is normally live (archived ones aren't reachable from the
    // sidebar), but it *can* be the one just deleted — the user can open an
    // archived chat from the Archived screen. Fall back like delete does.
    final activeId = gone.contains(state.activeId)
        ? (remaining.isEmpty ? null : remaining.first.id)
        : state.activeId;
    state = ChatSessionsState(
      conversations: remaining,
      activeId: activeId,
      phase: state.phase,
      error: state.error,
      awaitingPlan: state.awaitingPlan,
    );
  }

  /// Where to send the user when the chat with [id] stops being visible: stay
  /// put unless it was the open one, in which case fall back to the newest chat
  /// still in the sidebar (or a fresh compose when none is left).
  String? _activeIdAfterHiding(String id) {
    if (state.activeId != id) return state.activeId;
    for (final c in state.conversations) {
      if (c.id != id && !c.isArchived) return c.id;
    }
    return null;
  }

  /// Swap one conversation in place, keeping the rest of the state as-is.
  /// Deliberately does not re-sort: archiving and unarchiving both leave
  /// [Conversation.updatedAt] alone, so the list order is already right.
  void _replace(Conversation conversation, {required String? activeId}) {
    state = ChatSessionsState(
      conversations: [
        for (final c in state.conversations)
          if (c.id == conversation.id) conversation else c,
      ],
      activeId: activeId,
      phase: state.phase,
      error: state.error,
      awaitingPlan: state.awaitingPlan,
    );
  }

  /// Put work the assistant did on its own into the chat: the result of a
  /// scheduled task, delivered into the conversation with id [id] (created,
  /// named [title], the first time that task produces anything).
  ///
  /// It arrives like any other message the assistant sent — but it must never
  /// take over: whatever chat is open stays open, and a reply in flight is left
  /// alone. The task's chat simply appears in the sidebar (newest first, like
  /// every other), for the user to read when they want to.
  void deliverFromAgent({
    required String id,
    required String title,
    required String text,
    required DateTime at,
  }) {
    if (text.trim().isEmpty) return;

    final existing = _find(id);
    final message = ChatMessage(role: ChatRole.assistant, text: text.trim());
    final conversation =
        (existing ??
                Conversation(
                  id: id,
                  title: title,
                  model: '',
                  createdAt: at,
                  updatedAt: at,
                ))
            .copyWith(
              updatedAt: at,
              messages: [...?existing?.messages, message],
            );

    _store.save(conversation);
    state = ChatSessionsState(
      conversations: [
        if (existing == null) conversation,
        for (final c in state.conversations)
          if (c.id == id) conversation else c,
      ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
      activeId: state.activeId,
      phase: state.phase,
      error: state.error,
    );
  }

  Future<void> send({
    required NetworkCredential network,
    required String model,
    required String message,
    PlaygroundModality modality = PlaygroundModality.text,
    List<MediaAttachment> attachments = const [],
    bool? planFirst,
  }) async {
    final text = message.trim();
    if (text.isEmpty || state.sending) return;

    // Plan mode's planning turn: only when the composer is set to Plan (unless
    // the caller forced it — the approve path forces it off) and the agent is
    // the one answering, since a relay/media turn has no plan/act split.
    final planTurn =
        (planFirst ??
            ref.read(agentApprovalModeProvider) == AgentApprovalMode.plan) &&
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
      outputsDir: ref.read(mediaOutputsDirProvider),
    );
    final base = _activeOrNew(model);
    final withUser = base.copyWith(
      model: model,
      updatedAt: DateTime.now(),
      messages: [...base.messages, userTurn],
    );
    // A chat is named once — from its first message, until the agent replaces
    // that with a name for what it's actually about. Re-deriving on every turn
    // would drag it back to the first line the user typed ("hi") and undo that.
    final conversation = withUser.title == kNewConversationTitle
        ? withUser.copyWith(title: deriveConversationTitle(withUser.messages))
        : withUser;
    _commit(conversation, phase: const SendBusy());

    // Plain text goes through the agent (it can use tools and keeps the
    // conversation's context); pictures — generating one, or a turn that carries
    // attachments — go straight to the grid's chat API, which is the only one
    // that can see or make them. Everything downstream (folding updates,
    // persistence) is identical: both implement [ChatSender].
    final project = ref.read(projectByIdProvider(conversation.projectId));
    final updates = _senderFor(modality, attachments).send(
      network: network,
      model: model,
      history: conversation.messages,
      modality: modality,
      attachments: attachments,
      // The chat's project, so the agent answers with that folder open. Null for
      // a chat that belongs to no project (it falls back to the app's folder).
      workdir: project?.path,
      // The project's house rules, prepended to the agent's first turn.
      instructions: project?.instructions,
      // Lets the agent sender keep one live session per conversation and send
      // only the new turn (the API sender ignores it).
      conversationId: conversation.id,
      // A planning turn runs read-only and asks the agent to lay out a plan.
      planFirst: planTurn,
    );

    // Fold updates through a stored subscription so [stop] and disposal can
    // cancel an in-flight reply instead of letting it write back later.
    final done = _done = Completer<void>();
    String? agentSessionId;
    _sub = updates.listen(
      (update) {
        // The conversation may have been deleted mid-flight — drop the update
        // rather than resurrect it.
        final current = _find(conversation.id);
        if (current == null) return;
        switch (update) {
          case ChatSendGenerating(:final progress, :final status):
            state = _withPhase(
              SendGenerating(progress: progress, status: status),
            );
          case ChatSendStreaming(:final text):
            state = _withPhase(SendStreaming(text));
          case ChatSendAgentSession(:final sessionId):
            agentSessionId = sessionId;
          case ChatSendSuccess(:final reply):
            final answered = current.copyWith(
              updatedAt: DateTime.now(),
              messages: [...current.messages, reply],
            );
            // A planning turn's reply is a plan waiting on approval — light the
            // "approve & run" bar. Any other reply leaves it dark.
            _commit(answered, phase: const SendIdle(), awaitingPlan: planTurn);
            _adoptAgentName(answered, agentSessionId);
          case ChatSendFailure(:final error):
            state = _withPhase(const SendIdle(), error: error);
        }
      },
      onDone: _finish,
      onError: (Object _) => _finish(),
      cancelOnError: true,
    );
    return done.future;
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
    _store.save(renamed);
    state = ChatSessionsState(
      conversations: [
        for (final c in state.conversations)
          if (c.id == conversationId) renamed else c,
      ],
      activeId: state.activeId,
      phase: state.phase,
      error: state.error,
    );
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

  /// Stop an in-flight reply, keeping whatever the assistant had already said.
  ///
  /// The user's turn is persisted up front, but a half-written answer lives only
  /// in [SendStreaming] — dropping it would wipe text the user is reading, and
  /// they usually stop *because* they've read enough of it. Nothing streamed yet
  /// (the agent still thinking) means there's nothing to keep.
  void stop() {
    _cancel();
    if (!state.sending) return;

    final phase = state.phase;
    final partial = phase is SendStreaming ? phase.text.trim() : '';
    final current = state.active;
    if (partial.isEmpty || current == null) {
      state = _withPhase(const SendIdle());
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

  /// Settle the current send: drop the subscription and complete the future
  /// [send] returned (whether it finished on its own or was cancelled).
  void _finish() {
    _sub = null;
    final done = _done;
    _done = null;
    if (done != null && !done.isCompleted) done.complete();
  }

  void _cancel() {
    _sub?.cancel();
    _finish();
  }

  /// The open conversation, or a fresh (unsaved) one seeded with [model] and the
  /// project the user started it in.
  Conversation _activeOrNew(String model) {
    final active = state.active;
    if (active != null) return active;
    final now = DateTime.now();
    return Conversation(
      id: now.microsecondsSinceEpoch.toString(),
      title: kNewConversationTitle,
      model: model,
      createdAt: now,
      updatedAt: now,
      projectId: _draftProjectId,
    );
  }

  Conversation? _find(String id) {
    for (final c in state.conversations) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Approve the plan the agent just proposed: carry it out. The execute turn
  /// continues the same session (so the agent already has the plan in context)
  /// with the planning flag off, so it runs asking per action rather than
  /// planning again. A no-op unless a plan is actually waiting.
  Future<void> approvePlan() {
    if (!state.awaitingPlan || state.sending) return Future.value();
    final network = ref.read(selectedNetworkProvider);
    final active = state.active;
    if (network == null || active == null) return Future.value();
    return send(
      network: network,
      model: active.model,
      message: 'The plan looks good — go ahead and carry it out.',
      planFirst: false,
    );
  }

  /// Dismiss the proposed plan without running it — the plan stays in the
  /// transcript, but the "approve & run" bar goes away and the user can just
  /// carry on chatting.
  void dismissPlan() {
    if (!state.awaitingPlan) return;
    state = ChatSessionsState(
      conversations: state.conversations,
      activeId: state.activeId,
      phase: state.phase,
      error: state.error,
    );
  }

  /// Drop the last turn's failure.
  ///
  /// For when the thing the message described stops being true — handing the
  /// chat to a different agent, say. Left up, the sentence keeps blaming an
  /// agent that is no longer answering, above a button offering to switch back
  /// to it.
  void clearError() {
    if (state.error == null) return;
    state = ChatSessionsState(
      conversations: state.conversations,
      activeId: state.activeId,
      phase: state.phase,
      awaitingPlan: state.awaitingPlan,
    );
  }

  /// Upsert [conversation], re-sort newest-first, make it active and persist.
  /// [awaitingPlan] lights the plan-approval bar — set only after a planning
  /// turn's reply lands, and default-off everywhere else so any other commit
  /// (a new send, a stopped turn) clears it.
  void _commit(
    Conversation conversation, {
    required SendPhase phase,
    bool awaitingPlan = false,
  }) {
    // Talking in a chat un-files it. Reaching an archived chat takes opening it
    // from the Archived screen, and once the user types into it, leaving it
    // hidden would mean their reply lands somewhere the sidebar never shows —
    // the chat would look lost the moment they navigated away.
    final saved = conversation.isArchived
        ? conversation.copyWith(clearArchivedAt: true)
        : conversation;
    _store.save(saved);
    final list = [
      saved,
      for (final c in state.conversations)
        if (c.id != saved.id) c,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    state = ChatSessionsState(
      conversations: list,
      activeId: saved.id,
      phase: phase,
      awaitingPlan: awaitingPlan,
    );
  }

  ChatSessionsState _withPhase(SendPhase phase, {String? error}) =>
      ChatSessionsState(
        conversations: state.conversations,
        activeId: state.activeId,
        phase: phase,
        error: error,
      );
}
