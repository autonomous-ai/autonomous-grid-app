/// How Hermes takes a message typed while it is already working.
///
/// Unlike Claude Code and Codex, its ACP adapter has no separate channel for
/// this: the text goes out as an ordinary `session/prompt` carrying the
/// adapter's own `/steer` command, and the adapter hands it to the running agent
/// (`AIAgent.steer` in `run_agent.py`, hermes-agent 0.19.0), which appends it to
/// the last tool result so the model reads it on its next iteration.
///
/// Pure so it can be tested without a session: the whole feature turns on this
/// text being exactly what the adapter matches on, and a typo would look like an
/// agent that ignored the user.
library;

/// The command the adapter matches (`server.py`'s `_SLASH_COMMANDS`).
const String kHermesSteerCommand = '/steer';

/// [text] as the prompt that steers the running turn.
String hermesSteerPrompt(String text) => '$kHermesSteerCommand ${text.trim()}';

/// The openings of the adapter's own answers to a `/steer`.
///
/// It replies in the agent's voice — an `agent_message_chunk` on the running
/// turn — so without this the acknowledgement would be pasted into the middle of
/// the answer the user is reading.
const List<String> _acknowledgements = [
  '⏩ Steer queued for the active turn',
  'No active turn — queued for the next turn',
  '⚠️ Steer failed',
  'Usage: /steer',
];

/// Whether [text] is the adapter talking about a steer rather than the model
/// answering — see [_acknowledgements].
bool isHermesSteerAck(String text) {
  final said = text.trim();
  return _acknowledgements.any(said.startsWith);
}

/// The raw reason inside an acknowledgement, or null when Hermes took the
/// message.
///
/// Only the adapter's own failure counts as a refusal. "Queued for the next
/// turn" does not: the message is with Hermes either way, and its drain loop
/// runs it before the turn's response comes back — so it is still answered in
/// the turn the user is watching.
String? hermesSteerRefusal(String text) {
  final said = text.trim();
  return said.startsWith('⚠️ Steer failed') || said.startsWith('Usage: /steer')
      ? said
      : null;
}
