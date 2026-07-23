import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/hermes_version_service.dart';
import '../../agent/logic/codex_tool.dart';
import '../../agent/logic/hermes_tool.dart';
import 'agent_catalog.dart';

/// Whether [tool] is installed on this computer, keyed by the agent so a row
/// reads its *own* state instead of every row assuming Hermes.
final agentInstalledProvider = Provider.family<bool, AgentTool>((ref, tool) {
  return switch (tool) {
    AgentTool.hermes => ref.watch(hermesInstalledProvider),
    AgentTool.codex => ref.watch(codexInstalledProvider),
  };
});

/// Whether *any* agent is installed — the one thing chat routing needs to know
/// to decide between an agent answering and the grid's chat API. Which agent
/// answers is [activeChatAgentProvider]'s job.
final anyAgentInstalledProvider = Provider<bool>((ref) {
  for (final tool in AgentTool.values) {
    if (ref.watch(agentInstalledProvider(tool))) return true;
  }
  return false;
});

/// The installed build of [tool], or null when it isn't installed (or didn't
/// say which build it is). Same keying as [agentInstalledProvider].
final agentVersionProvider = FutureProvider.family<String?, AgentTool>((
  ref,
  tool,
) async {
  return switch (tool) {
    AgentTool.hermes => ref.watch(hermesVersionProvider.future),
    AgentTool.codex => ref.watch(codexVersionProvider.future),
  };
});

/// Re-read whether [tool] is on this computer, and which build it is.
///
/// The probe behind [agentInstalledProvider] walks the PATH once and then caches
/// the answer for the app's lifetime, so **anything that installs or removes an
/// agent has to say so here**. The first-run installer didn't: it finished
/// `grid agent install hermes` and every screen kept answering with the probe
/// taken at launch — Agents read "Not installed", and chat routed straight past
/// the agent — until the user quit and reopened the app.
void reprobeAgent(Ref ref, AgentTool tool) {
  switch (tool) {
    case AgentTool.hermes:
      ref.invalidate(hermesPathProvider);
      ref.invalidate(hermesVersionProvider);
    case AgentTool.codex:
      ref.invalidate(codexPathProvider);
      ref.invalidate(codexVersionProvider);
  }
}

/// Re-read every agent — for a caller that changed one without naming it. The
/// first-run installer runs a *plan*, so it knows something was installed but
/// not which tool it was.
void reprobeAgents(Ref ref) {
  for (final tool in AgentTool.values) {
    reprobeAgent(ref, tool);
  }
}
