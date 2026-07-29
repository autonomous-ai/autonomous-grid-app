import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/hermes_extensions.dart';
import 'package:grid_app/features/agent/logic/hermes_mcp_config.dart';
import 'package:grid_app/features/connectors/logic/connectors_controller.dart';
import 'package:grid_app/features/connectors/logic/manual_server_store.dart';
import 'package:grid_app/features/agents/logic/mcp_server.dart';

void main() {
  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('grid_mcp_ctrl_test');
  });
  tearDown(() => home.delete(recursive: true));

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        hermesMcpConfigProvider.overrideWithValue(
          HermesMcpConfig(home: home.path),
        ),
        // Not optional. Without it the controller reaches the real
        // `~/.grid/connectors/manual.json`, and a `remove` in any test rewrites
        // the developer's own store to `{}` — which is exactly what happened
        // the first time this ran.
        manualServerStoreProvider.overrideWithValue(
          ManualServerStore(home: home),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('a fresh config lists no servers', () async {
    expect(await container().read(mcpServersProvider.future), isEmpty);
  });

  test('save adds a server and the list reflects it', () async {
    final c = container();
    await c.read(mcpServersProvider.future);

    final error = await c
        .read(mcpServersProvider.notifier)
        .save(
          const McpServer(
            name: 'notion',
            transport: McpHttp(url: 'https://n'),
          ),
        );

    expect(error, isNull);
    expect(c.read(mcpServersProvider).value!.single.name, 'notion');
  });

  test('remove drops the server from the list', () async {
    final c = container();
    final notifier = c.read(mcpServersProvider.notifier);
    await c.read(mcpServersProvider.future);
    await notifier.save(
      const McpServer(
        name: 'notion',
        transport: McpHttp(url: 'https://n'),
      ),
    );

    await notifier.remove('notion');

    expect(c.read(mcpServersProvider).value, isEmpty);
  });
}
