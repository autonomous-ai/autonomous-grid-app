import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/logic/agent_extensions.dart';
import '../../agents/logic/mcp_server.dart';
import 'connector.dart';
import 'connector_catalog.dart';
import 'connector_link_controller.dart';

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
  // The gateway's per-device list is the third source, and the only optional
  // one: it says whether the *account* is linked. A poll that fails or a user
  // who is signed out leaves the rows reading from config and catalog alone,
  // which is the same screen this was before the gateway existed.
  final linked = ref.watch(deviceConnectorsProvider).asData?.value ?? const [];
  return buildConnectors(
    servers: servers,
    catalog: catalog,
    deviceConnectors: linked,
  );
});

class McpServersController extends AsyncNotifier<List<McpServer>> {
  @override
  Future<List<McpServer>> build() {
    final tool = ref.watch(extensionAgentProvider);
    final plane = ref.watch(agentExtensionsProvider(tool))?.mcp;
    return plane?.read() ?? Future.value(const []);
  }

  AgentMcpPlane? get _plane {
    final tool = ref.read(extensionAgentProvider);
    return ref.read(agentExtensionsProvider(tool))?.mcp;
  }

  /// Add or replace a server. Returns null on success, else a line to show —
  /// every caller is a button and needs something to say on failure.
  Future<String?> save(McpServer server) =>
      _act((plane) => plane.upsert(server));

  /// Save [server] over the entry called [previousName] — the rename path,
  /// one call so no dialog open-codes the remove-then-save dance.
  Future<String?> rename(String previousName, McpServer server) =>
      _act((plane) => plane.rename(previousName, server));

  Future<String?> remove(String name) => _act((plane) => plane.remove(name));

  Future<String?> _act(Future<void> Function(AgentMcpPlane) write) async {
    final plane = _plane;
    if (plane == null) return _noMcp;
    try {
      await write(plane);
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
