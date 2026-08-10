/// Where the [AgentExtensions] contract is wired to the adapters implementing it.
///
/// Deliberately not in `agent_extensions.dart`: the contract must not know which
/// agents exist. When it did, every adapter that imported the contract pulled the
/// list of adapters back in with it — a cycle between `features/agents` and
/// `features/agent` that made "adding an agent means writing one adapter" untrue,
/// because the contract had to be edited too.
///
/// Adding an agent now touches this file and that agent's own adapter, and leaves
/// the contract alone.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'adapters/claude_extensions.dart';
import 'adapters/codex_extensions.dart';
import 'adapters/hermes_extensions.dart';
import 'adapters/pi_extensions.dart';
import 'agent_catalog.dart';
import 'agent_extensions.dart';

/// The extension adapter for [tool], or null when that agent has none yet.
///
/// Exhaustive over [AgentTool], so wiring a new agent's adapter is a compile
/// error here rather than a silent gap in the screens.
final agentExtensionsProvider = Provider.family<AgentExtensions?, AgentTool>((
  ref,
  tool,
) {
  return switch (tool) {
    AgentTool.hermes => ref.watch(hermesExtensionsProvider),
    AgentTool.codex => ref.watch(codexExtensionsProvider),
    AgentTool.claude => ref.watch(claudeExtensionsProvider),
    AgentTool.pi => ref.watch(piExtensionsProvider),
  };
});

/// Which agent the Skills/Connectors/Plugins screens are scoped to.
///
/// Always Hermes today; the notifier exists so those screens are already
/// written against "the selected agent" and a future agent switcher is a UI
/// change, not a plumbing one.
final extensionAgentProvider =
    NotifierProvider<ExtensionAgentNotifier, AgentTool>(
      ExtensionAgentNotifier.new,
    );

/// Holds the agent those screens are pointed at, and switches it.
class ExtensionAgentNotifier extends Notifier<AgentTool> {
  @override
  AgentTool build() => AgentTool.hermes;

  void select(AgentTool tool) => state = tool;
}
