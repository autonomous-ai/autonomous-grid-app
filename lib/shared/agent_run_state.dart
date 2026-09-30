/// The states an agent run is in, drawn the way Claude Code's VS Code panel
/// draws a session: a small dot whose colour says whether the agent is
/// working, waiting on the user, or has failed.
///
/// Shared rather than a feature's own: the dot is a shared widget
/// (`agent_run_indicator.dart`), and both the chat list and the agent feed
/// draw it — the one that decides a chat's state lives with the chat
/// (`chat_run_state.dart`).
enum AgentRunState { running, waiting, idle, unread, failed }
