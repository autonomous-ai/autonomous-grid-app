import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/adapters/hermes_mcp_config.dart';
import 'package:grid_app/features/agents/logic/mcp_server.dart';

void main() {
  late Directory home;
  late File config;
  late HermesMcpConfig subject;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('grid_mcp_test');
    config = File('${home.path}/.hermes/config.yaml');
    subject = HermesMcpConfig(home: home.path);
  });
  tearDown(() => home.delete(recursive: true));

  test('a missing config reads as no servers', () async {
    expect(await subject.read(), isEmpty);
  });

  test('upsert writes a server the reader can read back', () async {
    await subject.upsert(
      const McpServer(
        name: 'notion',
        transport: McpStdio(command: 'npx', args: ['-y', 'server-notion']),
      ),
    );

    final servers = await subject.read();
    expect(servers.single.name, 'notion');
    expect(mcpServerSummary(servers.single), 'npx -y server-notion');
  });

  test('upsert leaves the rest of the config untouched', () async {
    await config.parent.create(recursive: true);
    await config.writeAsString('approvals:\n  cron_mode: deny\n');

    await subject.upsert(
      const McpServer(
        name: 'r',
        transport: McpHttp(url: 'https://x'),
      ),
    );

    final text = await config.readAsString();
    expect(text, contains('cron_mode: deny'));
    expect(text, contains('mcp_servers:'));
  });

  test('a write backs up the previous config to .bak', () async {
    await config.parent.create(recursive: true);
    await config.writeAsString('approvals:\n  cron_mode: deny\n');

    await subject.upsert(
      const McpServer(
        name: 'r',
        transport: McpHttp(url: 'https://x'),
      ),
    );

    expect(File('${config.path}.bak').existsSync(), isTrue);
  });

  test(
    'upsert with an existing name replaces that server, not adds a copy',
    () async {
      await subject.upsert(
        const McpServer(
          name: 'r',
          transport: McpHttp(url: 'https://old'),
        ),
      );
      await subject.upsert(
        const McpServer(
          name: 'r',
          transport: McpHttp(url: 'https://new'),
        ),
      );

      final servers = await subject.read();
      expect(servers, hasLength(1));
      expect(mcpServerSummary(servers.single), 'https://new');
    },
  );

  test('remove drops just that server', () async {
    await subject.upsert(
      const McpServer(
        name: 'a',
        transport: McpHttp(url: 'https://a'),
      ),
    );
    await subject.upsert(
      const McpServer(
        name: 'b',
        transport: McpHttp(url: 'https://b'),
      ),
    );

    await subject.remove('a');

    expect((await subject.read()).map((s) => s.name), ['b']);
  });

  test('removing an absent server is a no-op, not an error', () async {
    await subject.remove('ghost');
    expect(await subject.read(), isEmpty);
  });
}
