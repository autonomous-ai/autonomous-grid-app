/// The chat a turn is answering, handed to the agent as an environment
/// variable.
///
/// An agent that schedules something has no way to say where the answer should
/// come back to: it knows it is in a conversation, but not which one the app
/// calls it. So a task set up mid-chat delivered into a thread of its own, and
/// the chat that asked for it never heard back — which reads exactly like the
/// task not having run.
///
/// An environment variable rather than a line in the prompt: it costs no
/// context, it cannot be paraphrased or "helpfully" corrected by the model, and
/// a shell command can use it directly (`--deliver grid:chat:$GRID_CHAT_ID`).
const String kGridChatIdEnv = 'GRID_CHAT_ID';

/// The Grid-specific environment for one turn in [conversationId].
///
/// Empty when the turn has no conversation yet — a chat that hasn't been saved
/// has no id to deliver into, and an empty variable would have the agent write
/// `grid:chat:` into a job nothing could route.
Map<String, String> gridTurnEnv(String? conversationId, {String? turnId}) {
  final env = <String, String>{
    if (turnId != null && turnId.isNotEmpty) ...{
      // Both CLIs hand these through as their outbound request header. Claude
      // Code reads `ANTHROPIC_CUSTOM_HEADERS` ("Name: Value"); Codex reads
      // `OPENAI_CUSTOM_HEADERS`. Each lands as the same X-Request-Id so the
      // relay attributes every call of this turn to one id.
      'ANTHROPIC_CUSTOM_HEADERS': 'X-Request-Id: $turnId',
      'OPENAI_CUSTOM_HEADERS': 'X-Request-Id: $turnId',
    },
  };
  if (conversationId != null && conversationId.isNotEmpty) {
    env[kGridChatIdEnv] = conversationId;
  }
  return env;
}
