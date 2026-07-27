import 'agent_definition.dart';
import 'codex/codex_agent.dart';
import 'hermes/hermes_agent.dart';

/// The agents this build can run, in display order — the one list that replaces
/// `AgentTool.values`.
///
/// Every entry runs today: installed through the `grid` CLI (`grid agent
/// install`) and able to answer chats on this computer. An agent the app
/// can't install doesn't belong here — a row the user can only look at answers
/// nothing. Adding an agent is adding its [AgentDefinition] to this list (and
/// its icon to `pubspec.yaml`).
const List<AgentDefinition> kAgents = [HermesAgent(), CodexAgent()];

/// The definition for [id], or null when this build has no such agent — a
/// remembered choice for a since-dropped agent resolves to null and the caller
/// falls back (see `activeChatAgentProvider`).
AgentDefinition? agentById(String id) {
  for (final agent in kAgents) {
    if (agent.id == id) return agent;
  }
  return null;
}

/// The agent that answers chats before the user picks one, and the only agent
/// first-run setup treats as required (was `kChatAgent`). Named rather than
/// assumed, so the places that assume "the agent" stay findable — and `const`,
/// so it is the same instance as its entry in [kAgents].
const AgentDefinition kDefaultChatAgent = HermesAgent();
