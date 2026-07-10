import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../codex_agent/logic/codex_chat_sender.dart';
import '../../codex_agent/logic/codex_providers.dart';
import '../../playground/logic/chat_message.dart';
import '../../playground/logic/chat_sender.dart';
import '../../playground/logic/media_outputs.dart';
import '../../playground/logic/playground_request.dart';
import 'chat_store.dart';
import 'conversation.dart';

export '../../playground/logic/chat_message.dart'
    show ChatRole, ChatMessage, ChatMedia, SendPhase, SendBusy, SendGenerating;

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

  @override
  ChatSessionsState build() {
    ref.onDispose(_cancel);
    final conversations = ref.read(chatStoreProvider).loadAll();
    return ChatSessionsState(
      conversations: conversations,
      activeId: conversations.isEmpty ? null : conversations.first.id,
    );
  }

  ChatStore get _store => ref.read(chatStoreProvider);

  /// Open a fresh, empty compose. Not persisted until the first message, so
  /// clicking "New chat" repeatedly never litters the history with blanks.
  void newChat() {
    if (state.sending) return;
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
    final conversation =
        withUser.copyWith(title: deriveConversationTitle(withUser.messages));
    _commit(conversation, phase: const SendBusy());

    // Agent mode routes the turn through codex (text only) instead of the relay
    // chat sender; everything downstream — folding updates, persistence — is
    // identical because both implement [ChatSender].
    final agentMode = ref.read(codexAgentEnabledProvider);
    final sender = agentMode
        ? ref.read(codexChatSenderProvider)
        : ref.read(chatSenderProvider);
    final updates = sender.send(
          network: network,
          model: model,
          history: conversation.messages,
          modality: agentMode ? PlaygroundModality.text : modality,
          attachments: agentMode ? const [] : attachments,
        );

    // Fold updates through a stored subscription so [stop] and disposal can
    // cancel an in-flight reply instead of letting it write back later.
    final done = _done = Completer<void>();
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
          case ChatSendSuccess(:final reply):
            _commit(
              current.copyWith(
                updatedAt: DateTime.now(),
                messages: [...current.messages, reply],
              ),
              phase: const SendIdle(),
            );
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

  /// The open conversation, or a fresh (unsaved) one seeded with [model].
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
