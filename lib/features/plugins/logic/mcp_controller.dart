import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'hermes_mcp_config.dart';
import 'mcp_server.dart';

/// The MCP config seam. A plain provider so tests can point it at a temp home.
final hermesMcpConfigProvider = Provider<HermesMcpConfig>(
  (ref) => HermesMcpConfig(),
);

/// The MCP servers configured for Hermes, read straight from its config so the
/// screen and the agent can't disagree.
///
/// Every change writes through [HermesMcpConfig] and re-reads, so a server that
/// shows up here is one Hermes will actually load on its next session.
final mcpServersProvider =
    AsyncNotifierProvider<McpServersController, List<McpServer>>(
      McpServersController.new,
    );

class McpServersController extends AsyncNotifier<List<McpServer>> {
  @override
  Future<List<McpServer>> build() => ref.read(hermesMcpConfigProvider).read();

  /// Add or replace a server. Returns null on success, else a line to show —
  /// every caller is a button and needs something to say on failure.
  Future<String?> save(McpServer server) =>
      _act((config) => config.upsert(server));

  Future<String?> remove(String name) => _act((config) => config.remove(name));

  Future<String?> _act(Future<void> Function(HermesMcpConfig) write) async {
    final config = ref.read(hermesMcpConfigProvider);
    try {
      await write(config);
    } on Object catch (error) {
      return "Couldn't update the MCP servers: $error";
    }
    state = AsyncData(await config.read());
    return null;
  }
}
