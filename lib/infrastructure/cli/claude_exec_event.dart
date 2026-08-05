import 'agent_event.dart';

/// One thing to show from a running Claude Code turn — the same shapes the Chat
/// tab already renders for Hermes and Codex ([AgentActivity], [AgentPlanEntry],
/// a chunk of the answer), so all three agents feed the one activity/plan feed.
///
/// Claude speaks its own JSONL over `claude -p --output-format stream-json`, so
/// it gets its own thin envelope — but the payloads are the shared,
/// agent-neutral ones, so nothing downstream has to know which agent produced
/// them.
sealed class ClaudeExecEvent {
  const ClaudeExecEvent();
}

/// Claude's id for the conversation, seen once in the `init` line of the first
/// turn. The sender keeps it so the next turn can `claude --resume <id>` instead
/// of replaying the whole conversation.
class ClaudeSessionStarted extends ClaudeExecEvent {
  const ClaudeSessionStarted(this.sessionId);
  final String sessionId;
}

/// Which MCP servers the turn opened with, and whether each one had finished
/// its handshake by the time the tool list closed.
///
/// Measured, not theoretical: with the user's own `~/.claude.json` loaded (14
/// servers) the browser server was still `pending` at that moment and the turn
/// ran with 27 tools and no browser; narrowed to the app's own config it came up
/// `connected` and the turn carried 49. A browser lane that quietly lost its
/// tools looks exactly like a model that chose not to browse, so the sender
/// reads this and says so in the log.
class ClaudeServersAnnounced extends ClaudeExecEvent {
  const ClaudeServersAnnounced(this.statuses);

  /// Server name → the status the CLI reported (`connected`, `pending`,
  /// `failed`, `needs-auth`).
  final Map<String, String> statuses;
}

/// A command, look-up, file edit or thought Claude produced while answering.
class ClaudeActivityEvent extends ClaudeExecEvent {
  const ClaudeActivityEvent(this.activity);
  final AgentActivity activity;
}

/// The answer so far — the full assembled text, not a delta, so the sender
/// replaces rather than appends.
class ClaudeMessageEvent extends ClaudeExecEvent {
  const ClaudeMessageEvent(this.text);
  final String text;
}

/// Claude's to-do list as it stands now, replacing the previous one wholesale
/// (its `TodoWrite` tool always sends the whole list).
class ClaudePlanEvent extends ClaudeExecEvent {
  const ClaudePlanEvent(this.entries);
  final List<AgentPlanEntry> entries;
}

/// Claude is *about* to write [path] — emitted from the tool call, before the
/// tool has run.
///
/// The timing is the point: it is the last moment the file's previous contents
/// still exist, so this is what lets the chat show an honest before/after and
/// back a real undo. Codex reports its writes only after the fact, which is why
/// its changes can only ever offer "open the new file".
class ClaudeFileWriteStarted extends ClaudeExecEvent {
  const ClaudeFileWriteStarted(this.callId, this.path);

  /// Claude's `tool_use` id, so the matching result can be recognised.
  final String callId;
  final String path;
}

/// The write to [path] landed. Paired with an earlier [ClaudeFileWriteStarted];
/// a write that failed produces no such event, because it changed nothing.
class ClaudeFileWriteFinished extends ClaudeExecEvent {
  const ClaudeFileWriteFinished(this.path);
  final String path;
}

/// The turn failed for good — the model stream broke, auth was rejected, the
/// grid didn't answer. Carries Claude's own last words, humanized by the sender.
class ClaudeTurnFailed extends ClaudeExecEvent {
  const ClaudeTurnFailed(this.message);
  final String message;
}

/// Claude ended the turn by itself — it was done, not cut off. The chat needs
/// the difference: a turn that finished normally with a to-do step left unticked
/// is the model's own sloppy bookkeeping, not work it abandoned (see
/// [agentTurnStalled]).
class ClaudeTurnCompleted extends ClaudeExecEvent {
  const ClaudeTurnCompleted();
}
