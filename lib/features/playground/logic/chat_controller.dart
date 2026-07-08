import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import 'chat_message.dart';
import 'chat_sender.dart';
import 'playground_request.dart';

export 'chat_message.dart' show ChatRole, ChatMessage, ChatMedia, ChatState;

/// Drives the Playground transcript — a single throwaway smoke test, cleared
/// when the dialog closes. It builds the running transcript and delegates the
/// actual dispatch to [ChatSender], folding each [ChatSendUpdate] into its
/// state. The persistent, multi-conversation Chat tab shares the same sender.
final chatControllerProvider =
    NotifierProvider<ChatController, ChatState>(ChatController.new);

class ChatController extends Notifier<ChatState> {
  @override
  ChatState build() => const ChatState();

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

    final history = [
      ...state.messages,
      ChatMessage(role: ChatRole.user, text: text),
    ];
    state = ChatState(messages: history, phase: const SendBusy());

    final updates = ref.read(chatSenderProvider).send(
          network: network,
          model: model,
          history: history,
          modality: modality,
          attachments: attachments,
          localBaseUrl: localBaseUrl,
        );

    await for (final update in updates) {
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
    }
  }

  void clear() => state = const ChatState();
}
