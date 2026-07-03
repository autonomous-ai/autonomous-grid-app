import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/media_event.dart';
import '../../../infrastructure/cli/command_log.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import 'chat_message.dart';
import 'chat_transport.dart';
import 'media_outputs.dart';
import 'media_transport.dart';
import 'playground_request.dart';

export 'chat_message.dart' show ChatRole, ChatMessage, ChatMedia, ChatState;

/// Drives the Playground transcript. Everything goes over HTTP now (no CLI):
/// - **Text** (and the local-engine smoke test) → OpenAI `chat/completions`.
/// - **Image** → `media/image/generate`, or `media/image/edit` when the user
///   attached source images.
/// - **Video** → `media/video/i2v` (requires one attached starting image).
///
/// The endpoint is chosen from the selected model's [PlaygroundModality]. The
/// transcript is local UI state; media results are saved under `~/.grid/outputs`
/// and rendered inline from disk.
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

    // The local smoke test and relay text both hit chat/completions; only the
    // base URL differs (the local engine has no `/relay/v1` prefix).
    if (localBaseUrl != null) {
      return _runChat(
        endpoint: '$localBaseUrl/v1/chat/completions',
        network: network,
        model: model,
        history: history,
      );
    }

    switch (modality) {
      case PlaygroundModality.text:
        return _runChat(
          endpoint: '${network.relayBaseUrl}/chat/completions',
          network: network,
          model: model,
          history: history,
        );
      case PlaygroundModality.image:
        final edit = attachments.isNotEmpty;
        return _runMedia(
          network: network,
          operation: edit ? MediaOperation.imageEdit : MediaOperation.imageGenerate,
          payload: edit
              ? imageEditPayload(text, attachments)
              : imageGeneratePayload(text),
          history: history,
        );
      case PlaygroundModality.video:
        if (attachments.isEmpty) {
          return _fail(history, 'Add a starting image to make a video.');
        }
        return _runMedia(
          network: network,
          operation: MediaOperation.i2v,
          payload: i2vPayload(text, attachments.first),
          history: history,
        );
    }
  }

  /// One-shot chat completion (relay or local). Mirrors the call into the Debug
  /// tab and maps failures to a plain-language line.
  Future<void> _runChat({
    required String endpoint,
    required NetworkCredential network,
    required String model,
    required List<ChatMessage> history,
  }) async {
    final log = ref.read(commandLogProvider.notifier);
    final id = log.begin(CliCallKind.http, 'POST $endpoint');

    final (reply, error) = await ref.read(chatTransportProvider).complete(
          endpoint: endpoint,
          apiKey: network.relayApiKey,
          model: model,
          messages: _messagesFor(history),
        );
    log.finish(id, exitCode: error?.statusCode ?? 200, error: error?.message);

    if (error != null) return _fail(history, _friendlyChatError(error));
    final answer = (reply == null || reply.isEmpty)
        ? 'The model returned no text.'
        : reply;
    state = ChatState(
      messages: [...history, ChatMessage(role: ChatRole.assistant, text: answer)],
    );
  }

  /// Streams a media generation, surfacing progress as it arrives, then saves
  /// the result to `~/.grid/outputs` and appends it to the transcript.
  Future<void> _runMedia({
    required NetworkCredential network,
    required MediaOperation operation,
    required Map<String, dynamic> payload,
    required List<ChatMessage> history,
  }) async {
    final url = '${network.relayBaseUrl}/${operation.path}';
    final log = ref.read(commandLogProvider.notifier);
    final id = log.begin(CliCallKind.http, 'POST $url');

    // Show a generating bubble right away, before the first progress event.
    state = ChatState(
      messages: history,
      phase: const SendGenerating(progress: 0, status: 'starting'),
    );

    MediaError? failure;
    List<MediaFile> result = const [];
    try {
      final events = ref.read(mediaTransportProvider).stream(
            url: url,
            apiKey: network.relayApiKey,
            payload: payload,
          );
      await for (final event in events) {
        switch (event) {
          case MediaProgress(:final progress, :final status):
            state = ChatState(
              messages: history,
              phase: SendGenerating(progress: _fraction(progress), status: status),
            );
          case MediaResult(:final files):
            result = files;
          case MediaError():
            failure = event;
        }
      }
    } on Object catch (e) {
      failure = MediaError('$e');
    }

    if (failure != null) {
      log.finish(id, error: failure.message);
      return _fail(history, failure.message);
    }
    if (result.isEmpty) {
      log.finish(id, error: 'No media returned.');
      return _fail(history, 'The grid finished but returned no media.');
    }

    final saved = await saveMediaOutputs(result, ref.read(mediaOutputsDirProvider));
    log.finish(id, exitCode: 200);
    if (saved.isEmpty) {
      return _fail(history, "The generated files couldn't be read.");
    }
    state = ChatState(
      messages: [...history, ChatMessage(role: ChatRole.assistant, media: saved)],
    );
  }

  void clear() => state = const ChatState();

  void _fail(List<ChatMessage> history, String error) =>
      state = ChatState(messages: history, error: error);

  /// Builds the OpenAI messages array from the text turns (media-only turns
  /// carry no text and are skipped).
  List<Map<String, String>> _messagesFor(List<ChatMessage> history) => [
        {'role': 'system', 'content': 'You are a helpful assistant.'},
        for (final m in history)
          if (m.text.isNotEmpty)
            {
              'role': m.role == ChatRole.user ? 'user' : 'assistant',
              'content': m.text,
            },
      ];

  /// Turns a transport failure into one plain line; the raw detail stays in the
  /// Debug log. We surface the relay's actual reason (out of credit, expired
  /// session) rather than a blanket "is a model running?" guess.
  static String _friendlyChatError(ChatTransportError error) {
    if (error.statusCode == 401 || error.statusCode == 403) {
      return 'Your session expired — please sign in again.';
    }
    final detail = error.message.trim();
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

  /// Normalizes the relay's progress number to 0–1, tolerating either a percent
  /// (0–100, as the CLI prints) or an already-fractional value.
  static double _fraction(double progress) =>
      (progress <= 1 ? progress : progress / 100).clamp(0.0, 1.0);
}
