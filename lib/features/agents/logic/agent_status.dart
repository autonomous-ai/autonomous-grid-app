import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agent/agent_definition.dart';
import '../../agent/agent_registry.dart';

/// Whether the agent with [id] is installed on this computer, keyed by the
/// agent's id so a row reads its *own* state instead of every row assuming
/// Hermes. Delegates to the definition, so adding an agent needs no case here.
final agentInstalledProvider = Provider.family<bool, String>(
  (ref, id) => agentById(id)?.installed(ref) ?? false,
);

/// Whether *any* agent is installed — the one thing chat routing needs to know
/// to decide between an agent answering and the grid's chat API. Which agent
/// answers is `activeChatAgentProvider`'s job.
final anyAgentInstalledProvider = Provider<bool>((ref) {
  for (final agent in kAgents) {
    if (ref.watch(agentInstalledProvider(agent.id))) return true;
  }
  return false;
});

/// The installed build of the agent with [id], or null when it isn't installed
/// (or didn't say which build it is). Same keying as [agentInstalledProvider].
final agentVersionProvider = FutureProvider.family<String?, String>((
  ref,
  id,
) async {
  final agent = agentById(id);
  return agent == null ? null : await agent.version(ref);
});

/// Re-read whether [agent] is on this computer, and which build it is.
///
/// The probe behind [agentInstalledProvider] walks the PATH once and then caches
/// the answer for the app's lifetime, so **anything that installs or removes an
/// agent has to say so here**. The first-run installer once didn't: it finished
/// `grid agent install` and every screen kept answering with the probe taken at
/// launch — Agents read "Not installed", and chat routed straight past the agent
/// — until the user quit and reopened the app.
void reprobeAgent(Ref ref, AgentDefinition agent) => agent.reprobe(ref);

/// Re-read every agent — for a caller that changed one without naming it. The
/// first-run installer runs a *plan*, so it knows something was installed but
/// not which agent it was.
void reprobeAgents(Ref ref) {
  for (final agent in kAgents) {
    agent.reprobe(ref);
  }
}
