import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/hermes_version_service.dart';
import '../../agent/logic/codex_tool.dart';
import '../../agent/logic/hermes_tool.dart';
import 'agent_catalog.dart';

/// Whether [tool] is installed on this computer, keyed by the agent so a row
/// reads its *own* state instead of every row assuming Hermes. A planned agent
/// (nothing the CLI can install) is never installed.
final agentInstalledProvider = Provider.family<bool, AgentTool>((ref, tool) {
  return switch (tool) {
    AgentTool.hermes => ref.watch(hermesInstalledProvider),
    AgentTool.codex => ref.watch(codexInstalledProvider),
    AgentTool.openclaw => false,
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
    AgentTool.openclaw => null,
  };
});
