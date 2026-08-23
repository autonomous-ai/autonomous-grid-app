import 'package:grid_app/core/agent_homes.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/adapters/claude_connector_servers.dart';
import 'package:grid_app/features/agents/logic/adapters/codex_connector_servers.dart';
import 'package:grid_app/features/agents/logic/adapters/hermes_connector_servers.dart';
import 'package:grid_app/features/agents/logic/connector_token.dart';

/// Every agent gets every connector, and none of them gets a credential.
///
/// This pins the rule that replaced two different ones: Codex and Claude Code
/// used to skip a header-bearing MCP connector outright, and Hermes used to
/// write the header into `config.yaml` (the D17 debt). Now all three render the
/// same loopback address and the app spends the credential per request.
void main() {
  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('projection-transport');
    // Hermes takes its *hermes home*; the other two take a user home. The
    // asymmetry is real and has already cost one wrong measurement.
    await Directory(
      AgentHomes.hermesProfile(home.path),
    ).create(recursive: true);
    await Directory('${home.path}/.codex').create(recursive: true);
  });

  tearDown(() => home.delete(recursive: true));

  String? bridge(String connector) => 'http://127.0.0.1:61755/c/$connector/mcp';

  /// An MCP connector whose entry carries the credential — the whole of path A.
  ConnectorToken withHeader() => const ConnectorToken(
    connector: 'canva',
    accessToken: 'secret-token',
    mcpEntry: McpEntry(
      url: 'https://mcp.canva.com/mcp',
      headers: {'Authorization': 'Bearer secret-token'},
    ),
  );

  /// An MCP connector that needs no credential attached.
  ConnectorToken withoutHeader() => const ConnectorToken(
    connector: 'deepwiki',
    accessToken: 'unused',
    mcpEntry: McpEntry(url: 'https://mcp.deepwiki.com/mcp'),
  );

  Future<Map<String, Object?>> codexEntries(Directory h) async {
    final servers = CodexConnectorServers(
      home: h.path,
      bridgeEndpointFor: bridge,
    );
    return servers.readEntries();
  }

  test(
    'a header-bearing connector reaches all three, via the bridge',
    () async {
      final tokens = [withHeader()];

      await HermesConnectorServers(
        home: AgentHomes.hermesProfile(home.path),
        bridgeEndpointFor: bridge,
      ).project(tokens);
      await CodexConnectorServers(
        home: home.path,
        bridgeEndpointFor: bridge,
      ).project(tokens);
      await ClaudeConnectorServers(
        home: home.path,
        bridgeEndpointFor: bridge,
      ).project(tokens);

      final hermes = await File(
        '${AgentHomes.hermesProfile(home.path)}/config.yaml',
      ).readAsString();
      final codex = await File(
        '${home.path}/.codex/config.toml',
      ).readAsString();
      final claude = await File('${home.path}/.claude.json').readAsString();

      for (final entry in {
        'hermes': hermes,
        'codex': codex,
        'claude': claude,
      }.entries) {
        expect(
          entry.value,
          contains('127.0.0.1:61755/c/canva/mcp'),
          reason: '${entry.key} should point at the bridge',
        );
        // The point of the whole detour: the credential stays in the master
        // store. This is D17 staying repaid.
        expect(
          entry.value,
          isNot(contains('secret-token')),
          reason: '${entry.key} must not carry the credential',
        );
        expect(entry.value, isNot(contains('Authorization')));
      }
    },
  );

  test('a connector needing no credential points at its own server', () async {
    // Routing this through the bridge would buy nothing and would make it stop
    // working whenever Grid is closed.
    final tokens = [withoutHeader()];

    await CodexConnectorServers(
      home: home.path,
      bridgeEndpointFor: bridge,
    ).project(tokens);

    final entries = await codexEntries(home);
    expect(
      (entries['deepwiki']! as Map)['url'],
      'https://mcp.deepwiki.com/mcp',
    );
  });

  test('before the bridge binds, a header-bearing entry is skipped', () async {
    // Skipping is not an error and not permanent — the next projection writes
    // it. Writing a URL that resolves to nothing would be worse.
    await CodexConnectorServers(
      home: home.path,
      bridgeEndpointFor: (_) => null,
    ).project([withHeader()]);

    final file = File('${home.path}/.codex/config.toml');
    // Rule 3: writing nothing writes nothing.
    expect(await file.exists(), isFalse);
  });

  test('Claude Code keeps every key outside mcpServers', () async {
    // `~/.claude.json` is the agent's entire state — 70-odd root keys covering
    // projects, history and onboarding — not a settings file. A bad write here
    // costs the user their install.
    final file = File('${home.path}/.claude.json');
    await file.writeAsString(
      jsonEncode({
        'projects': {'/a': 1, '/b': 2},
        'onboarding': {'done': true},
        'mcpServers': {
          'mine': {'type': 'http', 'url': 'https://example.test/mcp'},
        },
      }),
    );

    await ClaudeConnectorServers(
      home: home.path,
      bridgeEndpointFor: bridge,
    ).project([withHeader()]);

    final after = jsonDecode(await file.readAsString()) as Map;
    expect((after['projects']! as Map).length, 2);
    expect(after['onboarding'], {'done': true});
    // The user's own entry is untouched: an entry without our marker is theirs.
    expect(
      ((after['mcpServers']! as Map)['mine']! as Map)['url'],
      'https://example.test/mcp',
    );
    expect((after['mcpServers']! as Map).containsKey('canva'), isTrue);
  });

  test('a server the user configured by hand is never overwritten', () async {
    final file = File('${home.path}/.codex/config.toml');
    await file.writeAsString(
      '[mcp_servers.canva]\n'
      "url = 'https://canva.example/mine'\n",
    );

    await CodexConnectorServers(
      home: home.path,
      bridgeEndpointFor: bridge,
    ).project([withHeader()]);

    final entries = await codexEntries(home);
    expect(
      (entries['canva']! as Map)['url'],
      'https://canva.example/mine',
      reason: 'no marker means the user wrote it',
    );
  });
}
