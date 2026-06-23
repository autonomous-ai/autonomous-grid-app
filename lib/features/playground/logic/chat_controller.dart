import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/providers.dart';

final chatControllerProvider =
    NotifierProvider<ChatController, ChatState>(ChatController.new);

enum ChatRole { user, assistant }

class ChatMessage {
  const ChatMessage({required this.role, required this.text});
  final ChatRole role;
  final String text;
}

class ChatState {
  const ChatState({
    this.messages = const [],
    this.sending = false,
    this.error,
  });

  final List<ChatMessage> messages;
  final bool sending;
  final String? error;
}

/// Consumer chat via the CLI smoke-test path:
/// `grid request chat --network <net> --model <model> --message "<msg>"`.
/// Each send is a standalone, non-streaming request (the CLI keeps no history),
/// so the transcript is local UI state only.
class ChatController extends Notifier<ChatState> {
  @override
  ChatState build() => const ChatState();

  Future<void> send({
    required String network,
    required String model,
    required String message,
  }) async {
    final text = message.trim();
    if (text.isEmpty || state.sending) return;

    final history = [
      ...state.messages,
      ChatMessage(role: ChatRole.user, text: text),
    ];

    final service = ref.read(gridCliServiceProvider);
    if (service == null) {
      state = ChatState(messages: history, error: 'grid executable not found.');
      return;
    }

    state = ChatState(messages: history, sending: true);
    final result = await service.run([
      'request', 'chat',
      '--network', network,
      '--model', model,
      '--message', text,
    ]);

    if (!result.ok) {
      state = ChatState(messages: history, error: result.errorMessage);
      return;
    }

    final reply = result.stdout.trim();
    state = ChatState(
      messages: [
        ...history,
        ChatMessage(
          role: ChatRole.assistant,
          text: reply.isEmpty ? '(empty response)' : reply,
        ),
      ],
    );
  }

  void clear() => state = const ChatState();
}
