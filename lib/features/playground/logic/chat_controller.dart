import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import 'chat_message.dart';
import 'chat_sender.dart';
import 'media_outputs.dart';
import 'playground_request.dart';

export 'chat_message.dart' show ChatRole, ChatMessage, ChatMedia, ChatState;

/// Drives the Playground transcript — a single throwaway smoke test, cleared
/// when the dialog closes. It builds the running transcript and delegates the
/// actual dispatch to [ChatSender], folding each [ChatSendUpdate] into its
/// state. The persistent, multi-conversation Chat tab shares the same sender.
final chatControllerProvider =
    NotifierProvider<ChatController, ChatState>(ChatController.new);

class ChatController extends Notifier<ChatState> {
  StreamSubscription<ChatSendUpdate>? _sub;
  Completer<void>? _done;

  @override
  ChatState build() {
    ref.onDispose(_cancel);
    return const ChatState();
  }

  Future<void> send({
    required NetworkCredential network,
    required String model,
    required String message,
    PlaygroundModality modality = PlaygroundModality.text,
    List<MediaAttachment> attachments = const [],
    String? localBaseUrl,
  }) async {
    final text = message.trim();
    if (text.isEmpty || state.sending) return;

    final userTurn = await buildUserTurn(
      text: text,
      attachments: attachments,
      outputsDir: ref.read(mediaOutputsDirProvider),
    );
    final history = [...state.messages, userTurn];
    state = ChatState(messages: history, phase: const SendBusy());

    final updates = ref.read(chatSenderProvider).send(
          network: network,
          model: model,
          history: history,
          modality: modality,
          attachments: attachments,
          localBaseUrl: localBaseUrl,
        );

    // Fold updates through a stored subscription rather than `await for`, so
    // closing the dialog ([clear]) can cancel it — a late update must never
    // resurrect a closed dialog's transcript (or leave the input locked).
    final done = _done = Completer<void>();
    _sub = updates.listen(
      (update) {
        switch (update) {
          case ChatSendGenerating(:final progress, :final status):
            state = ChatState(
              messages: history,
              phase: SendGenerating(progress: progress, status: status),
            );
          case ChatSendSuccess(:final reply):
            state = ChatState(messages: [...history, reply]);
          case ChatSendFailure(:final error):
            state = ChatState(messages: history, error: error);
        }
      },
      onDone: _finish,
      onError: (Object _) => _finish(),
      cancelOnError: true,
    );
    return done.future;
  }

  /// Cancel an in-flight send without wiping the transcript.
  void stop() => _cancel();

  /// Reset to an empty transcript, cancelling any in-flight send first so a
  /// late update can't write back after the dialog closes.
  void clear() {
    _cancel();
    state = const ChatState();
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
}
