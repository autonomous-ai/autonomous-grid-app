/// How Hermes reaches an MCP server: by spawning a local process, or by calling
/// a remote URL. The two transports carry different fields, so they're modelled
/// as a sealed pair rather than one class full of nullable both-ways columns.
sealed class McpTransport {
  const McpTransport();
}

/// A local server Hermes launches as a subprocess (the common case — most MCP
/// servers ship as an `npx`/`uvx` command).
class McpStdio extends McpTransport {
  const McpStdio({
    required this.command,
    this.args = const [],
    this.env = const {},
  });

  final String command;
  final List<String> args;
  final Map<String, String> env;
}

/// A remote server Hermes talks to over HTTP (e.g. a hosted connector).
class McpHttp extends McpTransport {
  const McpHttp({required this.url, this.headers = const {}});

  final String url;
  final Map<String, String> headers;
}

/// One configured MCP server: a [name] (its key in the config, and how its tools
/// are grouped) and the [transport] that reaches it.
class McpServer {
  const McpServer({required this.name, required this.transport});

  final String name;
  final McpTransport transport;

  /// The server as Hermes's `mcp_servers.<name>` value — only the fields that
  /// carry something, so a bare stdio server writes just its `command`.
  Map<String, Object?> toConfigValue() => switch (transport) {
    McpStdio(:final command, :final args, :final env) => {
      'command': command,
      if (args.isNotEmpty) 'args': args,
      if (env.isNotEmpty) 'env': env,
    },
    McpHttp(:final url, :final headers) => {
      'url': url,
      if (headers.isNotEmpty) 'headers': headers,
    },
  };
}

/// A one-line, human-readable summary of how a server is reached — the command
/// line for stdio, the URL for http. Used as the subtitle in the list and as the
/// text searched alongside the name.
String mcpServerSummary(McpServer server) => switch (server.transport) {
  McpStdio(:final command, :final args) => [command, ...args].join(' '),
  McpHttp(:final url) => url,
};

/// Read the servers out of a parsed `mcp_servers` node.
///
/// Lenient by design — the app shares `~/.hermes/config.yaml` with Hermes and
/// the user, so a hand-added or half-written entry is skipped, not fatal. A
/// server needs a name plus either a `command` (stdio) or a `url` (http); an
/// entry with neither is dropped.
List<McpServer> parseMcpServers(Object? node) {
  if (node is! Map) return const [];
  final servers = <McpServer>[];
  for (final entry in node.entries) {
    final name = entry.key;
    final value = entry.value;
    if (name is! String || name.trim().isEmpty || value is! Map) continue;
    final transport = _transportFrom(value);
    if (transport != null) {
      servers.add(McpServer(name: name, transport: transport));
    }
  }
  return servers;
}

McpTransport? _transportFrom(Map value) {
  final url = value['url'];
  if (url is String && url.trim().isNotEmpty) {
    return McpHttp(url: url, headers: _stringMap(value['headers']));
  }
  final command = value['command'];
  if (command is String && command.trim().isNotEmpty) {
    return McpStdio(
      command: command,
      args: _stringList(value['args']),
      env: _stringMap(value['env']),
    );
  }
  return null;
}

List<String> _stringList(Object? raw) => raw is! List
    ? const []
    : [
        for (final item in raw)
          if (item != null) '$item',
      ];

Map<String, String> _stringMap(Object? raw) => raw is! Map
    ? const {}
    : {
        for (final entry in raw.entries)
          if (entry.key is String && entry.value != null)
            entry.key as String: '${entry.value}',
      };
