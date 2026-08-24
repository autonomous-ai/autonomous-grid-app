import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/chat/logic/chat_sessions_controller.dart';
import 'grid_mcp_server.dart';

/// The one MCP server the app runs, wired to the chat controller.
///
/// Started once for the process and kept: the port is baked into every turn's
/// agent configuration, so a server that came and went would leave a turn
/// pointing at a closed socket. Stopped with the container.
final gridMcpServerProvider = Provider<GridMcpServer>((ref) {
  final server = GridMcpServer(
    onAsk: (chatId, call) =>
        ref.read(chatSessionsProvider.notifier).runAgentAsk(chatId, call),
  );
  ref.onDispose(server.stop);
  return server;
});

/// The `mcpServers` entry an agent needs to reach [server] for one turn.
///
/// Streamable HTTP with a bearer, because the server is in this process and
/// there is nothing to spawn. The token is minted per turn by the caller and is
/// what tells the server which chat the turn belongs to.
Map<String, Object?> gridMcpServerEntry({
  required String url,
  required String token,
}) => {
  'type': 'http',
  'url': url,
  'headers': {'Authorization': 'Bearer $token'},
};

/// The environment variable a Codex run reads its Grid token from.
const String kGridMcpTokenEnv = 'GRID_MCP_TOKEN';

/// The `-c` overrides that give a Codex run Grid's tools for one turn.
///
/// **`bearer_token_env_var`, not `bearer_token` and not a header.** Codex 0.144
/// refuses the first by name — "uses unsupported `bearer_token`; set
/// `bearer_token_env_var`" — and a token passed in argv is a token in `ps`. The
/// caller puts [kGridMcpTokenEnv] in the child's environment beside these.
///
/// Overrides, so nothing reaches `~/.codex/config.toml`. That file is shared
/// with the user's own Codex and with the ChatGPT desktop app, and it is where
/// Grid's servers used to be written.
List<String> gridMcpCodexOverrides({required String url}) => [
  'mcp_servers.grid.url="$url"',
  'mcp_servers.grid.bearer_token_env_var="$kGridMcpTokenEnv"',
];
