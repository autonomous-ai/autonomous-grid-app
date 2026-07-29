import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/mcp_server.dart';

void main() {
  group('parseMcpServers — reading Hermes\'s config leniently', () {
    test('reads a stdio server with args and env', () {
      final servers = parseMcpServers({
        'notion': {
          'command': 'npx',
          'args': ['-y', 'server-notion'],
          'env': {'TOKEN': 'secret'},
        },
      });
      expect(servers, hasLength(1));
      final transport = servers.single.transport;
      expect(servers.single.name, 'notion');
      expect(transport, isA<McpStdio>());
      transport as McpStdio;
      expect(transport.command, 'npx');
      expect(transport.args, ['-y', 'server-notion']);
      expect(transport.env, {'TOKEN': 'secret'});
    });

    test('reads an http server by its url', () {
      final servers = parseMcpServers({
        'remote': {
          'url': 'https://mcp.example.com',
          'headers': {'Authorization': 'Bearer x'},
        },
      });
      expect(servers.single.transport, isA<McpHttp>());
      final http = servers.single.transport as McpHttp;
      expect(http.url, 'https://mcp.example.com');
      expect(http.headers, {'Authorization': 'Bearer x'});
    });

    test('skips an entry with neither command nor url instead of throwing', () {
      final servers = parseMcpServers({
        'broken': {'note': 'nothing usable here'},
        'ok': {'command': 'uvx'},
      });
      expect(servers.map((s) => s.name), ['ok']);
    });

    test('a missing or non-map section reads as no servers', () {
      expect(parseMcpServers(null), isEmpty);
      expect(parseMcpServers('not a map'), isEmpty);
    });
  });

  group('toConfigValue — writing only the fields that carry something', () {
    test('a bare stdio server writes just its command', () {
      const server = McpServer(
        name: 'time',
        transport: McpStdio(command: 'uvx'),
      );
      expect(server.toConfigValue(), {'command': 'uvx'});
    });

    test('an http server without headers omits the headers key', () {
      const server = McpServer(
        name: 'r',
        transport: McpHttp(url: 'https://x'),
      );
      expect(server.toConfigValue(), {'url': 'https://x'});
    });
  });

  group('mcpServerSummary — the one-line subtitle', () {
    test('joins the command and its args for a local server', () {
      const server = McpServer(
        name: 'fs',
        transport: McpStdio(command: 'npx', args: ['-y', 'server-fs']),
      );
      expect(mcpServerSummary(server), 'npx -y server-fs');
    });

    test('shows the url for a remote server', () {
      const server = McpServer(
        name: 'r',
        transport: McpHttp(url: 'https://mcp.example.com'),
      );
      expect(mcpServerSummary(server), 'https://mcp.example.com');
    });
  });
}
