import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/logic/agent_extensions.dart';
import '../../agents/logic/mcp_server.dart';
import 'connector.dart';
import 'connector_catalog.dart';
import '../../agents/logic/connector_token.dart';
import 'connector_link_controller.dart';
import 'manual_server_store.dart';

/// The MCP servers configured for the selected agent, read straight from its
/// config so the screen and the agent can't disagree.
///
/// Every change writes through the agent's MCP plane and re-reads, so a server
/// that shows up here is one the agent will actually load on its next session.
final mcpServersProvider =
    AsyncNotifierProvider<McpServersController, List<McpServer>>(
      McpServersController.new,
    );

/// The full Connectors screen model: what's live in the agent's config joined
/// with what the catalog offers. The config side stays the only truth about
/// what the agent loads — the catalog only ever adds "available" rows.
final connectorsProvider = FutureProvider<List<Connector>>((ref) async {
  final servers = await ref.watch(mcpServersProvider.future);
  final catalog = await ref.watch(connectorCatalogProvider.future);
  // The third source: the credentials this machine actually holds. Optional —
  // an unreadable store leaves the rows reading from config and catalog alone,
  // which is the same screen this was before the gateway existed.
  final tokens =
      ref.watch(connectorTokensProvider).asData?.value ??
      const <String, ConnectorToken>{};
  return buildConnectors(servers: servers, catalog: catalog, tokens: tokens);
});

class McpServersController extends AsyncNotifier<List<McpServer>> {
  @override
  Future<List<McpServer>> build() async {
    final tool = ref.watch(extensionAgentProvider);
    final plane = ref.watch(agentExtensionsProvider(tool))?.mcp;
    if (plane == null) return const [];
    // Project the app's own record onto this agent before reading it back.
    // Selecting an agent for the first time — or switching to one — has to
    // carry the user's manual servers across, or they would appear to have
    // vanished with the agent that happened to be active when they were added.
    await _projectManual(plane);
    return plane.read();
  }

  /// Write every manually configured server into [plane], skipping the ones it
  /// already has.
  ///
  /// Additive on purpose: this never deletes. A server in the agent's config
  /// that the store doesn't know about was put there by the user or by Hermes
  /// itself, and removing it would destroy configuration this app never owned.
  Future<void> _projectManual(AgentMcpPlane plane) async {
    try {
      final stored = await ref.read(manualServerStoreProvider).read();
      if (stored.isEmpty) return;
      final existing = {for (final server in await plane.read()) server.name};
      for (final server in stored.values) {
        if (existing.contains(server.name)) continue;
        await plane.upsert(server);
      }
    } on Object {
      // A projection failure leaves the agent as it was; the screen still shows
      // whatever that agent has, and the store is untouched.
    }
  }

  AgentMcpPlane? get _plane {
    final tool = ref.read(extensionAgentProvider);
    return ref.read(agentExtensionsProvider(tool))?.mcp;
  }

  /// Add or replace a server. Returns null on success, else a line to show —
  /// every caller is a button and needs something to say on failure.
  Future<String?> save(McpServer server) => _act(
    store: (store) => store.save(server),
    project: (plane) => plane.upsert(server),
  );

  /// Save [server] over the entry called [previousName] — the rename path,
  /// one call so no dialog open-codes the remove-then-save dance.
  Future<String?> rename(String previousName, McpServer server) => _act(
    store: (store) => store.save(server, previousName: previousName),
    project: (plane) => plane.rename(previousName, server),
  );

  Future<String?> remove(String name) => _act(
    store: (store) => store.remove(name),
    project: (plane) => plane.remove(name),
  );

  /// Write to the app's own store, then into the selected agent's config.
  ///
  /// The order is the whole point. `~/.grid/connectors/manual.json` is the
  /// record that outlives any one agent — the same role `tokens.json` plays for
  /// OAuth connectors — and the agent's config is a projection of it. Writing
  /// only the agent would put the user's work inside Hermes, where switching to
  /// Codex loses it.
  ///
  /// A projection failure is still reported, but the store keeps the change:
  /// the user asked for it, and the next projection will carry it over.
  Future<String?> _act({
    required Future<void> Function(ManualServerStore) store,
    required Future<void> Function(AgentMcpPlane) project,
  }) async {
    try {
      await store(ref.read(manualServerStoreProvider));
    } on Object catch (error) {
      return "Couldn't save the connection: $error";
    }

    final plane = _plane;
    if (plane == null) {
      // Nothing to project onto. Not a failure — the record is safe, and it
      // will reach an agent that understands MCP as soon as one is selected.
      ref.invalidateSelf();
      return _noMcp;
    }

    try {
      await project(plane);
    } on AgentExtensionException catch (error) {
      return error.message;
    } on Object catch (error) {
      return "Couldn't update the MCP servers: $error";
    }
    state = AsyncData(await plane.read());
    return null;
  }

  static const _noMcp = "This agent doesn't support MCP servers.";
}
