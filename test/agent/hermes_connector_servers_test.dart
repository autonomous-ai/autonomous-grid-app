import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/hermes_connector_servers.dart';
import 'package:grid_app/features/agents/logic/connector_token.dart';

/// The half of the connector projection that writes `~/.hermes/config.yaml`.
///
/// Untested until 2026-07-30, which is when it silently deleted two working
/// connectors — so these start with that failure and work outwards.
void main() {
  late Directory home;
  late HermesConnectorServers servers;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('grid_connector_servers');
    servers = HermesConnectorServers(home: home.path);
  });
  tearDown(() => home.delete(recursive: true));

  ConnectorToken token(String connector) => ConnectorToken(
    connector: connector,
    accessToken: 'access-$connector',
    mcpEntry: McpEntry(
      url: 'https://mcp.example/$connector',
      headers: {'Authorization': 'Bearer access-$connector'},
      canRefresh: true,
    ),
  );

  Future<String> config() => servers.configFile.readAsString();

  group('writing entries', () {
    test('a projected connector becomes an mcp_servers entry', () async {
      await servers.project([token('linear')]);

      final text = await config();
      expect(text, contains('linear'));
      expect(text, contains('https://mcp.example/linear'));
      // The marker is what makes an entry ours to touch later.
      expect(await servers.owned(), {'linear'});
    });

    test('an entry the user wrote by hand is never overwritten', () async {
      await servers.configFile.writeAsString(
        'mcp_servers:\n  linear:\n    url: https://mine.example/mcp\n',
      );

      await servers.project([token('linear')]);

      // No `_grid` marker means somebody else's configuration, and replacing it
      // would lose work that exists nowhere else.
      expect(await config(), contains('https://mine.example/mcp'));
      expect(await servers.owned(), isEmpty);
    });
  });

  group('removing entries', () {
    test('a connector named in removing loses its entry', () async {
      await servers.project([token('linear'), token('notion')]);
      expect(await servers.owned(), {'linear', 'notion'});

      // Disconnecting has to actually stop the agent calling it.
      await servers.project([token('linear')], removing: {'notion'});

      expect(await servers.owned(), {'linear'});
      expect(await config(), isNot(contains('mcp.example/notion')));
    });

    test(
      'projecting an empty list deletes nothing — the 2026-07-30 regression',
      () async {
        await servers.project([token('linear'), token('notion')]);

        // What actually happened: one unrelated token expired, its failed
        // refresh emptied the master store, and this method — then deleting
        // every `_grid` entry absent from the list — took both working
        // connectors with it. An empty list cannot be distinguished from an
        // unreadable store, so it must never mean "delete everything".
        await servers.project(const []);

        expect(await servers.owned(), {'linear', 'notion'});
      },
    );

    test('an unrelated connector survives another one being removed', () async {
      await servers.project([token('linear'), token('notion')]);

      await servers.project([token('linear')], removing: {'notion'});

      expect(await servers.owned(), contains('linear'));
    });

    test('removing never touches an entry without the marker', () async {
      await servers.configFile.writeAsString(
        'mcp_servers:\n  handmade:\n    url: https://mine.example/mcp\n',
      );

      // Even asked directly, an entry this app did not write is not ours to
      // delete.
      await servers.project(const [], removing: {'handmade'});

      expect(await config(), contains('https://mine.example/mcp'));
    });
  });

  group('the rest of the file', () {
    test('unrelated config keys survive a projection', () async {
      await servers.configFile.writeAsString(
        'model: gpt-5\nskills:\n  external_dirs:\n    - ~/mine\n',
      );

      await servers.project([token('linear')]);

      final text = await config();
      expect(text, contains('model: gpt-5'));
      expect(text, contains('~/mine'));
      expect(text, contains('linear'));
    });

    test('a backup is written before the file changes', () async {
      await servers.configFile.writeAsString('model: gpt-5\n');

      await servers.project([token('linear')]);

      // This file is the user's, and a bad edit is not recoverable anywhere
      // else.
      expect(File('${servers.configFile.path}.bak').existsSync(), isTrue);
    });
  });
}
