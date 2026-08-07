import '../../../infrastructure/cli/agent_event.dart';
import 'chat_context.dart';
import 'chat_file.dart';
import 'message_media.dart';

export 'chat_context.dart';
export 'chat_file.dart';

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
    this.files = const [],
    this.contexts = const [],
    this.sources = const [],
    this.plan = const [],
    this.model,
    this.took,
    this.firstToken,
  });

  final ChatRole role;
  final String text;
  final List<ChatMedia> media;

  /// Documents the user attached to this turn — a report, a spreadsheet, a
  /// contract. Kept apart from [text] so the bubble shows them as files while the
  /// model reads their content (see [messageForModel]). Empty on assistant turns.
  final List<ChatFile> files;

  /// What the user had on screen when they sent this — the terminal open beside
  /// the conversation, captured as they pressed Send. Empty on assistant turns,
  /// and on any turn sent with no panel open.
  final List<ChatContext> contexts;

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

  /// How long this reply took to arrive — from the moment the turn was sent to
  /// the answer landing, so a queued agent turn isn't charged for the wait.
  ///
  /// Shown beside the model, because "which model" and "how long" are one
  /// question for a grid: the same prompt is seconds on one machine and minutes
  /// on another, and the model name alone gives no way to tell them apart. Null
  /// on the user's own turns, and on replies saved before this was recorded.
  final Duration? took;

  /// How long until the first word of the reply appeared, measured from the same
  /// start as [took].
  ///
  /// The half of "was that slow?" the total can't answer: a model that starts
  /// writing in a second and takes twenty is usable, one that thinks for
  /// nineteen and then dumps the same answer is not — and on an agent turn the
  /// gap is the tool work it did before it had anything to say. Null when the
  /// reply never streamed (a media turn, an answer that arrived whole) and on
  /// replies saved before this was recorded.
  final Duration? firstToken;

  ChatMessage copyWith({
    ChatRole? role,
    String? text,
    List<ChatMedia>? media,
    List<ChatFile>? files,
    List<ChatContext>? contexts,
    List<WebSource>? sources,
    List<AgentPlanEntry>? plan,
    String? model,
    Duration? took,
    Duration? firstToken,
  }) => ChatMessage(
    role: role ?? this.role,
    text: text ?? this.text,
    media: media ?? this.media,
    files: files ?? this.files,
    contexts: contexts ?? this.contexts,
    sources: sources ?? this.sources,
    plan: plan ?? this.plan,
    model: model ?? this.model,
    took: took ?? this.took,
    firstToken: firstToken ?? this.firstToken,
  );
}

/// The turn as a model reads it: what the user typed, then the text of any files
/// they attached, then what they had on screen.
///
/// These are joined only here, on the way out — the transcript keeps them apart
/// so the user's bubble stays the sentence they wrote with the files named
/// beside it, rather than the sentence buried under a spreadsheet. Every path
/// that sends a turn goes through this (relay chat, Responses, the agent
/// prompt), so a file attached in the composer reaches whoever answers.
///
/// Terminals come last because they are the least deliberate thing on the
/// message: a file was picked, a terminal was merely open.
String messageForModel(ChatMessage message) {
  if (message.files.isEmpty && message.contexts.isEmpty) return message.text;
  return [
    if (message.text.trim().isNotEmpty) message.text.trim(),
    for (final file in message.files) file.promptBlock,
    for (final context in message.contexts) context.promptBlock,
  ].join('\n\n');
}

/// How long a reply took, in the shortest form that stays honest: `840ms`,
/// `8.4s`, `42s`, `3m 20s`, `1h 04m`.
///
/// Sub-second turns keep milliseconds rather than rounding to `0.0s` — a turn
/// that failed before it began really did take 2ms, and the number saying so is
/// the first clue that nothing ran. Precision drops as the number grows: tenths
/// of a second stop meaning anything once a turn runs for a minute.
String formatTurnDuration(Duration took) {
  final ms = took.inMilliseconds;
  if (ms <= 0) return '0ms';
  if (ms < 1000) return '${ms}ms';
  if (ms < 10000) return '${(ms / 1000).toStringAsFixed(1)}s';
  final seconds = took.inSeconds;
  if (seconds < 60) return '${seconds}s';
  final minutes = took.inMinutes;
  if (minutes < 60) return '${minutes}m ${_pad(seconds % 60)}s';
  return '${took.inHours}h ${_pad(minutes % 60)}m';
}

/// Two digits, so `3m 05s` lines up with `3m 55s` instead of jumping a column.
String _pad(int value) => value.toString().padLeft(2, '0');

/// A model id as a person reads it — maker and model, punctuated the way every
/// other model on a grid already is (`qwen/qwen3.6-27b`).
///
/// A seat model reaches the app in the relay's own form, `kind:model`, with the
/// vendor's name usually sitting in both halves: `claude:claude-opus-5` said
/// "claude" twice and read as a config string rather than as Opus. This gives
/// `claude/opus-5`, and `codex-cli:gpt-5.6-terra` → `codex-cli/gpt-5.6-terra`.
///
/// Display only — the id itself is what a request carries, so this never goes on
/// the wire. Anything without a kind (a grid model, `auto`, the media modes)
/// comes back trimmed and otherwise untouched.
String modelDisplayLabel(String id) {
  final trimmed = id.trim();
  final colon = trimmed.indexOf(':');
  if (colon <= 0) return trimmed;
  final kind = trimmed.substring(0, colon);
  final name = _withoutRepeatedKind(trimmed.substring(colon + 1).trim(), kind);
  if (name.isEmpty) return trimmed;
  return '$kind/$name';
}

/// `claude-opus-5` served under the `claude` kind → `opus-5`. A name that
/// doesn't repeat its kind (`gpt-5.5` under `codex-cli`) is left whole, so
/// nothing a vendor actually named is trimmed away.
String _withoutRepeatedKind(String name, String kind) {
  final prefix = '$kind-';
  if (!name.toLowerCase().startsWith(prefix.toLowerCase())) return name;
  return name.substring(prefix.length);
}

/// A model id as the transcript shows it: the bare model name, dropping any
/// `maker/` prefix (`qwen/qwen3.6-27b` → `qwen3.6-27b`).
///
/// Reads the display form ([modelDisplayLabel]), so a seat model shortens the
/// same way its row in the picker does — `claude:claude-opus-5` → `opus-5`,
/// rather than the whole relay id for want of a slash.
///
/// Trimmed; an id that is blank or only a maker prefix comes back as given
/// rather than as an empty string.
String modelShortLabel(String id) {
  final display = modelDisplayLabel(id);
  final slash = display.lastIndexOf('/');
  if (slash == -1 || slash == display.length - 1) return display;
  return display.substring(slash + 1);
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
