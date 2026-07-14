import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../agent/logic/agent_routing.dart';
import '../../agent/logic/agent_session_title.dart';
import '../../agent/logic/hermes_chat_sender.dart';
import '../../agent/logic/hermes_tool.dart';
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
  });

  final List<Conversation> conversations;
  final String? activeId;
  final SendPhase phase;
  final String? error;

  /// The open conversation, or null while composing a new one.
  Conversation? get active {
    final id = activeId;
    if (id == null) return null;
    for (final c in conversations) {
      if (c.id == id) return c;
    }
    return null;
  }

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
    return ChatSessionsState(
      conversations: conversations,
      activeId: conversations.isEmpty ? null : conversations.first.id,
    );
  }

  ChatStore get _store => ref.read(chatStoreProvider);

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
  }) async {
    final text = message.trim();
    if (text.isEmpty || state.sending) return;

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
    final updates = _senderFor(modality, attachments).send(
      network: network,
      model: model,
      history: conversation.messages,
      modality: modality,
      attachments: attachments,
      // The chat's project, so the agent answers with that folder open. Null for
      // a chat that belongs to no project (it falls back to the app's folder).
      workdir: ref.read(projectByIdProvider(conversation.projectId))?.path,
      // Lets the agent sender keep one live session per conversation and send
      // only the new turn (the API sender ignores it).
      conversationId: conversation.id,
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
            _commit(answered, phase: const SendIdle());
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

    final current = _find(conversationId);
    if (current == null || current.title == title) return;
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
      agentInstalled: ref.read(hermesInstalledProvider),
    );
    return viaAgent
        ? ref.read(hermesChatSenderProvider)
        : ref.read(chatSenderProvider);
  }

  /// Stop an in-flight reply, leaving the already-persisted user turn in place
  /// and returning the composer to idle.
  void stop() {
    _cancel();
    if (state.sending) state = _withPhase(const SendIdle());
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

  /// Upsert [conversation], re-sort newest-first, make it active and persist.
  void _commit(Conversation conversation, {required SendPhase phase}) {
    _store.save(conversation);
    final list = [
      conversation,
      for (final c in state.conversations)
        if (c.id != conversation.id) c,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    state = ChatSessionsState(
      conversations: list,
      activeId: conversation.id,
      phase: phase,
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
