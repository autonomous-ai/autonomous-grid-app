/// What kind of step the agent is running.
enum AgentActivityKind { command, tool }

/// Lifecycle of one agent step, driving its live status indicator.
enum AgentActivityStatus { running, done, failed }

/// One agent step in the live activity feed — a shell command or a tool call the
/// agent ran while answering. Keyed by [id] so a `started` event and its later
/// `completed` event update the same row rather than duplicating it.
///
/// Lives in the infrastructure layer because the agent transport (Hermes over
/// ACP) emits these; the chat surfaces them in its "agent is working" bubble so
/// the user can see *what* the agent is doing, not just that it's busy.
class AgentActivity {
  const AgentActivity({
    required this.id,
    required this.kind,
    required this.label,
    required this.status,
  });

  final String id;
  final AgentActivityKind kind;

  /// Short human label — the shell command, or the tool name.
  final String label;
  final AgentActivityStatus status;
}
