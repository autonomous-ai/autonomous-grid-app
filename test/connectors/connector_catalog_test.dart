import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/mcp_server.dart';
import 'package:grid_app/features/connectors/logic/connector.dart';
import 'package:grid_app/features/connectors/logic/connector_catalog.dart';

void main() {
  group('sortCatalog', () {
    test('orders by the backend order, then by label', () {
      const a = ConnectorCatalogEntry(
        id: 'a',
        code: 'a',
        label: 'Zebra',
        description: '',
        order: 1,
      );
      const b = ConnectorCatalogEntry(
        id: 'b',
        code: 'b',
        label: 'Apple',
        description: '',
      );
      const c = ConnectorCatalogEntry(
        id: 'c',
        code: 'c',
        label: 'Mango',
        description: '',
      );
      expect(sortCatalog([b, c, a]).map((e) => e.code), ['a', 'b', 'c']);
    });
  });

  group('buildConnectors', () {
    const notion = ConnectorCatalogEntry(
      id: 'notion',
      code: 'notion',
      label: 'Notion',
      description: 'Pages and databases.',
      imageUrl: 'https://cdn.example/notion.png',
    );

    test(
      'a config entry with no catalog match is a connected custom server',
      () {
        final connectors = buildConnectors(
          servers: const [
            McpServer(
              name: 'my-db',
              transport: McpHttp(url: 'https://db'),
            ),
          ],
          catalog: const [],
        );
        expect(connectors.single.kind, ConnectorKind.customMcp);
        expect(connectors.single.connected, isTrue);
        expect(connectors.single.server, isNotNull);
        expect(connectors.single.imageUrl, isEmpty);
      },
    );

    test('a catalog entry with no config match is available', () {
      final connectors = buildConnectors(
        servers: const [],
        catalog: const [notion],
      );
      expect(connectors.single.kind, ConnectorKind.catalog);
      expect(connectors.single.connected, isFalse);
      expect(connectors.single.name, 'Notion');
      expect(connectors.single.imageUrl, 'https://cdn.example/notion.png');
      expect(connectors.single.server, isNull);
    });

    test('a connected catalog service shows once, under its catalog label', () {
      final connectors = buildConnectors(
        servers: const [
          McpServer(
            name: 'notion',
            transport: McpHttp(url: 'https://mcp.notion.com/mcp'),
          ),
        ],
        catalog: const [notion],
      );
      expect(connectors, hasLength(1));
      expect(connectors.single.kind, ConnectorKind.catalog);
      expect(connectors.single.connected, isTrue);
      // The catalog's label and mark win over the raw server key.
      expect(connectors.single.name, 'Notion');
      expect(connectors.single.imageUrl, 'https://cdn.example/notion.png');
      expect(connectors.single.catalogEntry, isNotNull);
    });

    test("the backend's installed flag never claims the agent is connected", () {
      const linked = ConnectorCatalogEntry(
        id: 'gmail',
        code: 'gmail',
        label: 'Gmail',
        description: '',
        installed: true,
      );
      // The account is linked at the backend, but this computer's agent has no
      // server for it — the row must not promise a tool the agent can't call.
      final connectors = buildConnectors(servers: const [], catalog: [linked]);
      expect(connectors.single.connected, isFalse);
    });

    test('connected rows come before available ones', () {
      final connectors = buildConnectors(
        servers: const [
          McpServer(
            name: 'my-db',
            transport: McpHttp(url: 'https://db'),
          ),
        ],
        catalog: const [notion],
      );
      expect(connectors.first.connected, isTrue);
      expect(connectors.last.connected, isFalse);
    });
  });
}
