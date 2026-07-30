import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/skills/agent_skill_home.dart';
import '../../agent/logic/hermes_extensions.dart';
import 'agent_catalog.dart';
import 'agent_plugin.dart';
import 'agent_skill.dart';
import 'connector_token.dart';
import 'mcp_server.dart';
import 'skill_writer.dart';

/// Every extension surface one agent exposes, one nullable plane per concept.
///
/// A null plane means the agent has no such concept — codex has skills but no
/// plugin manager — and the corresponding screen renders its "not supported by
/// this agent" state instead of pretending the plane is merely empty.
///
/// The Skills/Connectors/Plugins screens speak only to this contract, never to
/// a `Hermes*` class, mirroring how chat depends on `chatAgentSenderProvider`
/// rather than `HermesChatSender`. Adding an agent means writing one adapter.
abstract interface class AgentExtensions {
  AgentTool get tool;

  AgentSkillsPlane? get skills;

  AgentPluginsPlane? get plugins;

  AgentMcpPlane? get mcp;
}

/// The skills an agent reads, and — when safe — the authoring surface over them.
abstract interface class AgentSkillsPlane {
  /// Every skill in [source] — the app's own store, or an agent's private
  /// folder, whichever the screen is pointed at.
  Future<List<AgentSkill>> list(SkillSource source);

  /// Null when the agent can only display skills, not author them — the Skills
  /// screen hides Create/Edit/Delete when null.
  SkillWriter? get writer;

  /// Write (or refresh) the skills Grid ships for this agent. Idempotent —
  /// also the fix for a skill deleted by mistake.
  Future<void> installGridSkills();

  /// Make the agent-neutral store (`~/.grid/skills`) visible to this agent —
  /// Hermes by merging it into `skills.external_dirs`; Codex later by sync.
  /// Idempotent, and called before every authoring write so a skill can never
  /// land in a folder the agent doesn't read.
  Future<void> projectSharedStore();
}

/// The agent's plugin manager: whole tool backends with an on/off state.
abstract interface class AgentPluginsPlane {
  Future<List<AgentPlugin>> list();

  /// Add a plugin from a Git URL or `owner/repo`.
  Future<void> install(String identifier);

  Future<void> setEnabled(String name, {required bool enabled});

  Future<void> remove(String name);
}

/// The MCP servers the agent is configured to load.
abstract interface class AgentMcpPlane {
  Future<List<McpServer>> read();

  /// Add or replace a server, keyed by its name.
  Future<void> upsert(McpServer server);

  /// Remove the server named [name]; a no-op when it isn't there.
  Future<void> remove(String name);

  /// Replace the server saved under [previousName] with [server] — the rename
  /// path, centralized here so no caller open-codes the two-write dance.
  Future<void> rename(String previousName, McpServer server);

  /// The names of entries this app wrote as connector projections.
  ///
  /// [read] can't answer this: an [McpServer] carries only what a transport
  /// needs, so the marker distinguishing "we wrote this from a token" from "the
  /// user typed this" is dropped in parsing. Callers need the difference —
  /// adopting a projection as a manual server would copy a credential into a
  /// second file and resurrect the entry after a disconnect.
  ///
  /// Empty for an agent that has no such concept.
  Future<Set<String>> connectorEntries();

  /// Write [tokens] into whatever this agent reads OAuth credentials from, so a
  /// connector the user linked once works here too.
  ///
  /// The app's master store (`~/.grid/connectors/tokens.json`) is the source;
  /// this is the projection of it, the same way each agent gets a link to the
  /// master skills store. It can't be a symlink, because agents disagree about
  /// the format — so it's a transforming copy, and every change to the master
  /// re-projects. Idempotent: called again with the same tokens it rewrites the
  /// same bytes.
  ///
  /// Null when the agent has no OAuth-connector concept at all. That is the
  /// null-plane rule one level down: the screen says "not supported here"
  /// rather than promising a tool this agent could never call.
  Future<void> Function(List<ConnectorToken> tokens)?
  get projectConnectorTokens;
}

/// A plane operation failed in a way the user can act on. Adapters translate
/// their agent's own errors into this so every controller can surface
/// [message] without knowing which agent it came from.
class AgentExtensionException implements Exception {
  const AgentExtensionException(this.message);

  final String message;

  @override
  String toString() => message;
}

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
    // Codex keeps skills in ~/.codex/skills but has no adapter yet — its
    // extensions land with the codex adapter, not before.
    AgentTool.codex => null,
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

class ExtensionAgentNotifier extends Notifier<AgentTool> {
  @override
  AgentTool build() => AgentTool.hermes;

  void select(AgentTool tool) => state = tool;
}
