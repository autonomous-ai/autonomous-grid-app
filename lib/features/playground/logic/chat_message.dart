import 'message_media.dart';

/// Who authored a transcript message.
enum ChatRole { user, assistant }

/// A media file shown inline in the transcript — a generated image/video the
/// relay returned (saved under `~/.grid/outputs`) or an image the user attached
/// to a request. Rendered from its local [path]; [kind] picks the player.
class ChatMedia {
  const ChatMedia({required this.path, required this.kind});
  final String path;
  final MediaKind kind;
}

/// One turn in the Playground transcript. Carries text (chat replies) and/or
/// [media] (generated images/videos, or the image a user attached). Either may
/// be empty — a text reply has no media, an image result has no text.
class ChatMessage {
  const ChatMessage({
    required this.role,
    this.text = '',
    this.media = const [],
  });

  final ChatRole role;
  final String text;
  final List<ChatMedia> media;
}

/// What the controller is doing right now — modelled as a sealed hierarchy so
/// the UI switches exhaustively instead of juggling `sending`/`progress` flags.
sealed class SendPhase {
  const SendPhase();
}

/// Nothing in flight; the input is ready.
class SendIdle extends SendPhase {
  const SendIdle();
}

/// A request is in flight but reports no progress yet (chat, or a media request
/// before its first `progress` event).
class SendBusy extends SendPhase {
  const SendBusy();
}

/// A media generation is streaming progress. [progress] is 0–1; [status] is the
/// relay's short phase label (e.g. `running`).
class SendGenerating extends SendPhase {
  const SendGenerating({required this.progress, required this.status});
  final double progress;
  final String status;
}

/// An agent reply is streaming in. [text] is the whole reply so far, so the
/// trailing bubble grows live as tokens arrive. Empty until the first token.
class SendStreaming extends SendPhase {
  const SendStreaming(this.text);
  final String text;
}

/// The full Playground transcript state: the messages, the current [phase], and
/// the last error (cleared on the next send).
class ChatState {
  const ChatState({
    this.messages = const [],
    this.phase = const SendIdle(),
    this.error,
  });

  final List<ChatMessage> messages;
  final SendPhase phase;
  final String? error;

  /// True while a request is in flight — the input bar disables on this.
  bool get sending => phase is! SendIdle;
}
