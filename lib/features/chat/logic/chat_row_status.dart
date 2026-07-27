import '../../playground/logic/chat_message.dart';

/// What a chat row shows while a reply is still coming in — the coarse activity
/// behind the live [SendPhase], so the sidebar can say what a background chat is
/// doing.
///
/// Coarser than [SendPhase] on purpose: a row cares that a reply is *typing*,
/// not what the latest token was. Selecting on this (rather than the phase
/// itself) keeps the sidebar from rebuilding on every streamed character.
enum ChatActivity {
  /// The assistant is working before any answer text has arrived — an agent
  /// thinking or running its tools, or a plain reply not started yet.
  thinking,

  /// The answer is streaming in token by token.
  typing,

  /// A picture or video is being generated.
  creating,
}

/// The [ChatActivity] behind [phase], or null when the chat is idle.
ChatActivity? chatActivityFor(SendPhase phase) => switch (phase) {
  SendIdle() => null,
  SendBusy() => ChatActivity.thinking,
  SendGenerating() => ChatActivity.creating,
  SendStreaming() => ChatActivity.typing,
};
