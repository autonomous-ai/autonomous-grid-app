import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/media_event.dart';
import '../../../infrastructure/cli/command_log.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import 'chat_message.dart';
import 'chat_transport.dart';
import 'media_outputs.dart';
import 'media_transport.dart';
import 'playground_request.dart';

/// A single step in sending one message, streamed by [ChatSender.send]:
/// generation progress, then exactly one terminal [ChatSendSuccess] or
/// [ChatSendFailure]. Modelled as a sealed type so callers switch exhaustively
/// instead of juggling nullable reply/error/progress fields.
sealed class ChatSendUpdate {
  const ChatSendUpdate();
}

/// A media generation is streaming — [progress] is 0–1, [status] the relay's
/// short phase label. Never emitted for plain text chat.
class ChatSendGenerating extends ChatSendUpdate {
  const ChatSendGenerating(this.progress, this.status);
  final double progress;
  final String status;
}

/// The request finished; [reply] is the assistant turn to append (text for
/// chat, media for a generation).
class ChatSendSuccess extends ChatSendUpdate {
  const ChatSendSuccess(this.reply);
  final ChatMessage reply;
}

/// The request failed; [error] is a plain-language line safe to show the user.
class ChatSendFailure extends ChatSendUpdate {
  const ChatSendFailure(this.error);
  final String error;
}

/// Sends one chat/media message and streams its progress + outcome. The single
/// source of truth for *how* a message is dispatched, shared by the Playground
/// dialog and the Chat tab so both route, log and humanize failures identically:
/// - **Text** (and the local-engine smoke test) → OpenAI `chat/completions`.
/// - **Image** → `media/image/generate`, or `media/image/edit` with attachments.
/// - **Video** → `media/video/i2v` (needs one attached starting image).
///
/// It owns no transcript state — the caller passes the full [history] and folds
/// each [ChatSendUpdate] into its own state. Every call is mirrored into the
/// Debug command log.
abstract interface class ChatSender {
  Stream<ChatSendUpdate> send({
    required NetworkCredential network,
    required String model,
    required List<ChatMessage> history,
    PlaygroundModality modality = PlaygroundModality.text,
    List<MediaAttachment> attachments = const [],
    String? localBaseUrl,
  });
}

/// Wire [ChatSender] through the container so controllers stay testable — a
/// fake sender (or fake transports underneath) swaps in without a live relay.
final chatSenderProvider =
    Provider<ChatSender>((ref) => DefaultChatSender(ref));

/// The real [ChatSender], driving the HTTP chat/media transports.
class DefaultChatSender implements ChatSender {
  DefaultChatSender(this._ref);

  final Ref _ref;

  @override
  Stream<ChatSendUpdate> send({
    required NetworkCredential network,
    required String model,
    required List<ChatMessage> history,
    PlaygroundModality modality = PlaygroundModality.text,
    List<MediaAttachment> attachments = const [],
    String? localBaseUrl,
  }) {
    // The local smoke test and relay text both hit chat/completions; only the
    // base URL differs (the local engine has no `/relay/v1` prefix).
    if (localBaseUrl != null) {
      return _sendChat(
        endpoint: '$localBaseUrl/v1/chat/completions',
        network: network,
        model: model,
        history: history,
      );
    }

    switch (modality) {
      case PlaygroundModality.text:
        return _sendChat(
          endpoint: '${network.relayBaseUrl}/chat/completions',
          network: network,
          model: model,
          history: history,
        );
      case PlaygroundModality.image:
        final edit = attachments.isNotEmpty;
        return _sendMedia(
          network: network,
          operation:
              edit ? MediaOperation.imageEdit : MediaOperation.imageGenerate,
          payload: edit
              ? imageEditPayload(_lastPrompt(history), attachments)
              : imageGeneratePayload(_lastPrompt(history)),
        );
      case PlaygroundModality.video:
        if (attachments.isEmpty) {
          return Stream.value(
            const ChatSendFailure('Add a starting image to make a video.'),
          );
        }
        return _sendMedia(
          network: network,
          operation: MediaOperation.i2v,
          payload: i2vPayload(_lastPrompt(history), attachments.first),
        );
    }
  }

  /// One-shot chat completion (relay or local). Mirrors the call into the Debug
  /// tab and maps failures to a plain-language line.
  Stream<ChatSendUpdate> _sendChat({
    required String endpoint,
    required NetworkCredential network,
    required String model,
    required List<ChatMessage> history,
  }) async* {
    final log = _ref.read(commandLogProvider.notifier);
    final id = log.begin(CliCallKind.http, 'POST $endpoint');

    final (reply, error) = await _ref.read(chatTransportProvider).complete(
          endpoint: endpoint,
          apiKey: network.relayApiKey,
          model: model,
          messages: _messagesFor(history),
        );
    log.finish(id, exitCode: error?.statusCode ?? 200, error: error?.message);

    if (error != null) {
      yield ChatSendFailure(_friendlyChatError(error));
      return;
    }
    final answer = (reply == null || reply.isEmpty)
        ? 'The model returned no text.'
        : reply;
    yield ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: answer));
  }

  /// Streams a media generation, surfacing progress as it arrives, then saves
  /// the result to `~/.grid/outputs` and yields it as the assistant turn.
  Stream<ChatSendUpdate> _sendMedia({
    required NetworkCredential network,
    required MediaOperation operation,
    required Map<String, dynamic> payload,
  }) async* {
    final url = '${network.relayBaseUrl}/${operation.path}';
    final log = _ref.read(commandLogProvider.notifier);
    final id = log.begin(CliCallKind.http, 'POST $url');

    // Show a generating bubble right away, before the first progress event.
    yield const ChatSendGenerating(0, 'starting');

    MediaError? failure;
    List<MediaFile> result = const [];
    try {
      final events = _ref.read(mediaTransportProvider).stream(
            url: url,
            apiKey: network.relayApiKey,
            payload: payload,
          );
      await for (final event in events) {
        switch (event) {
          case MediaProgress(:final progress, :final status):
            yield ChatSendGenerating(_fraction(progress), status);
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
      yield ChatSendFailure(failure.message);
      return;
    }
    if (result.isEmpty) {
      log.finish(id, error: 'No media returned.');
      yield const ChatSendFailure('The grid finished but returned no media.');
      return;
    }

    final saved =
        await saveMediaOutputs(result, _ref.read(mediaOutputsDirProvider));
    log.finish(id, exitCode: 200);
    if (saved.isEmpty) {
      yield const ChatSendFailure("The generated files couldn't be read.");
      return;
    }
    yield ChatSendSuccess(ChatMessage(role: ChatRole.assistant, media: saved));
  }

  /// The most recent user prompt — the text a media generation renders.
  static String _lastPrompt(List<ChatMessage> history) {
    for (final m in history.reversed) {
      if (m.role == ChatRole.user && m.text.isNotEmpty) return m.text;
    }
    return '';
  }

  /// Builds the OpenAI messages array from the text turns (media-only turns
  /// carry no text and are skipped).
  static List<Map<String, String>> _messagesFor(List<ChatMessage> history) => [
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
