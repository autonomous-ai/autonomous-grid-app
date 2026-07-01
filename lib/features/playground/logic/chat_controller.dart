import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/command_log.dart';
import '../../../infrastructure/cli/grid_cli_service.dart';
import '../../../infrastructure/providers.dart';
import '../../auth/logic/session_controller.dart';
import 'chat_reply.dart';
import 'local_chat_client.dart';

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

/// Consumer chat. Two paths:
/// - Relay (default): runs `grid chat -m MODEL --grid GRID --json "MESSAGE"` —
///   single-turn, the CLI keeps no history.
/// - Local ([localBaseUrl] set): a direct OpenAI-style HTTP call to a
///   locally-running provider, like `curl localhost:PORT/v1/chat/completions`.
/// The transcript is local UI state either way.
class ChatController extends Notifier<ChatState> {
  @override
  ChatState build() => const ChatState();

  Future<void> send({
    required String network,
    required String model,
    required String message,
    String? localBaseUrl,
  }) async {
    final text = message.trim();
    if (text.isEmpty || state.sending) return;

    final history = [
      ...state.messages,
      ChatMessage(role: ChatRole.user, text: text),
    ];
    state = ChatState(messages: history, sending: true);

    final (reply, error) = localBaseUrl != null
        ? await _sendLocal(localBaseUrl, model, history)
        : await _sendViaCli(network: network, model: model, message: text);

    if (error != null) {
      state = ChatState(messages: history, error: error);
      return;
    }
    state = ChatState(
      messages: [
        ...history,
        ChatMessage(
          role: ChatRole.assistant,
          text: (reply == null || reply.isEmpty)
              ? 'The model returned no text.'
              : reply,
        ),
      ],
    );
  }

  Future<(String?, String?)> _sendViaCli({
    required String network,
    required String model,
    required String message,
  }) async {
    final service = ref.read(gridCliServiceProvider);
    if (service == null) {
      return (
        null,
        "Grid's background helper isn't available — please restart the app."
      );
    }

    final result = await service.run([
      'chat',
      '-m', model,
      '--grid', network,
      '--json', // print the full JSON response so we can pull out the text
      message,
    ]);
    // With --json the CLI prints the full JSON response — show just the
    // assistant text (parseChatReply also tolerates a plain-text fallback).
    return result.ok
        ? (parseChatReply(result.stdout), null)
        : (null, _friendlyChatError(result));
  }

  /// Maps a failed relay `chat` call to one plain-language line for the user;
  /// the raw CLI output is still captured in the Debug tab's command log. We
  /// surface the CLI's *actual* reason rather than a blanket "is a model
  /// running?" guess, which is misleading when the real cause is something else
  /// (e.g. an empty balance).
  static String _friendlyChatError(CliResult result) {
    if (result.sessionExpired) {
      return 'Your session expired — please sign in again.';
    }

    final detail = _errorDetail(result);
    if (detail.toLowerCase().contains('insufficient balance')) {
      return "You're out of credit on this grid — top up your balance, then "
          'try again.';
    }
    if (detail.isEmpty) {
      return "Couldn't get a reply. Make sure a model is running on this grid, "
          'then try again.';
    }
    return "Couldn't get a reply: $detail";
  }

  /// The CLI's own error reason, unwrapped from the relay's JSON error body
  /// (`{"detail": "..."}`) when present so we show the message, not the braces.
  static String _errorDetail(CliResult result) {
    final json = _jsonDetail(result.stderr) ?? _jsonDetail(result.stdout);
    return (json ?? result.errorMessage).trim();
  }

  static String? _jsonDetail(String text) =>
      RegExp(r'"detail"\s*:\s*"([^"]+)"').firstMatch(text)?.group(1);

  Future<(String?, String?)> _sendLocal(
    String baseUrl,
    String model,
    List<ChatMessage> history,
  ) async {
    final apiKey = ref.read(selectedNetworkProvider)?.accessToken ?? '';
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': 'You are a helpful assistant.'},
      for (final m in history)
        {
          'role': m.role == ChatRole.user ? 'user' : 'assistant',
          'content': m.text,
        },
    ];

    // Mirror the call into the Debug tab alongside the grid commands.
    final log = ref.read(commandLogProvider.notifier);
    final id = log.begin(CliCallKind.http, 'POST $baseUrl/v1/chat/completions');
    final (reply, error) = await LocalChatClient.complete(
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: model,
      messages: messages,
    );
    log.finish(id, exitCode: error == null ? 200 : null, error: error);
    return (reply, error);
  }

  void clear() => state = const ChatState();
}
