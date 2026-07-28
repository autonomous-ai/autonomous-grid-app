import '../../../infrastructure/cli/agent_event.dart';
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
    this.sources = const [],
    this.plan = const [],
    this.model,
  });

  final ChatRole role;
  final String text;
  final List<ChatMedia> media;

  /// Web pages an agent turn cited while answering — shown as clickable sources
  /// under the reply. Empty for user turns and for answers built without the
  /// web.
  final List<WebSource> sources;

  /// The to-do plan the agent worked through this turn — shown as a checklist
  /// under the reply. Empty for user turns and for simple answers the agent
  /// didn't plan out.
  final List<AgentPlanEntry> plan;

  /// The model that produced this reply, as the id the turn was sent with (e.g.
  /// `qwen/qwen3.6-27b`, or `auto`). Shown under the answer so the transcript
  /// says which model spoke. Set on assistant turns; null on the user's own, and
  /// on replies saved before this was recorded.
  final String? model;

  ChatMessage copyWith({
    ChatRole? role,
    String? text,
    List<ChatMedia>? media,
    List<WebSource>? sources,
    List<AgentPlanEntry>? plan,
    String? model,
  }) => ChatMessage(
    role: role ?? this.role,
    text: text ?? this.text,
    media: media ?? this.media,
    sources: sources ?? this.sources,
    plan: plan ?? this.plan,
    model: model ?? this.model,
  );
}

/// A model id as the transcript shows it: the bare model name, dropping any
/// `maker/` prefix (`qwen/qwen3.6-27b` → `qwen3.6-27b`).
///
/// Trimmed; an id that is blank or only a maker prefix comes back as given
/// rather than as an empty string.
String modelShortLabel(String id) {
  final trimmed = id.trim();
  final slash = trimmed.lastIndexOf('/');
  if (slash == -1 || slash == trimmed.length - 1) return trimmed;
  return trimmed.substring(slash + 1);
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
