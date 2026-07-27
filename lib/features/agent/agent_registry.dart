import '../../core/app_environment.dart';
import 'agent_definition.dart';
import 'codex/codex_agent.dart';
import 'hermes/hermes_agent.dart';
import 'openclaw/openclaw_agent.dart';

/// Every agent this build knows, in display order — the one list that replaces
/// `AgentTool.values`.
///
/// Installed through the `grid` CLI (or driven by its own tool) and able to
/// answer chats on this computer. Adding an agent is adding its
/// [AgentDefinition] here (and its icon to `pubspec.yaml`). A dev-only entry
/// (see [AgentDefinition.devOnly]) stays in this list but is filtered out of
/// [buildAgents] outside developer mode.
const List<AgentDefinition> kAgents = [
  HermesAgent(),
  CodexAgent(),
  OpenClawAgent(),
];

/// The agents this build actually offers the user. A dev-only agent — one whose
/// integration isn't finished (OpenClaw's transport still needs verifying
/// against a live binary) — appears only in developer builds; a shipped release
/// drops it so no user meets an agent that can't yet answer. Everything the UI
/// iterates and chat routing resolves goes through this, not [kAgents].
List<AgentDefinition> get buildAgents => [
  for (final agent in kAgents)
    if (!agent.devOnly || AppEnvironment.isDeveloperMode) agent,
];

/// The agents first-run setup fetches on its own — the non-dev-only ones this
/// build offers. A dev-only agent (OpenClaw, whose install path isn't proven out
/// yet) is left to a developer's explicit click, never auto-installed.
List<AgentDefinition> get installableAgents => [
  for (final agent in buildAgents)
    if (!agent.devOnly) agent,
];

/// The definition for [id] *offered in this build*, or null when there's no such
/// agent — a remembered choice for a since-dropped (or dev-only, in a release)
/// agent resolves to null and the caller falls back (see
/// `activeChatAgentProvider`). Resolves within [buildAgents], so a dev-only agent
/// can never come back to life through a stale preference in a shipped release.
AgentDefinition? agentById(String id) {
  for (final agent in buildAgents) {
    if (agent.id == id) return agent;
  }
  return null;
}

/// The agent that answers chats before the user picks one, and the only agent
/// first-run setup treats as required (was `kChatAgent`). Named rather than
/// assumed, so the places that assume "the agent" stay findable — and `const`,
/// so it is the same instance as its entry in [kAgents].
const AgentDefinition kDefaultChatAgent = HermesAgent();
