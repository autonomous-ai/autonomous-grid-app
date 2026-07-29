import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/mcp_server.dart';
import 'package:grid_app/features/connectors/logic/connector.dart';
import 'package:grid_app/features/connectors/logic/connector_catalog.dart';
import 'package:grid_app/infrastructure/api/connector_catalog_client.dart';

/// Trimmed from a real `GET /v1/connectors` body, keeping the shapes that
/// matter: an entry with no `order`, one with `mcp_url`, one that's already
/// linked, and two rows the parser must drop.
const _apiResponse = '''
{
  "status": 1,
  "data": {
    "connectors": [
      {
        "id": "6a213b5fe438b1a9f0629a86",
        "code": "google_drive",
        "label": "Google Drive",
        "image_url": "https://cdn.autonomous.ai/assets/icons/google_drive_icon.png",
        "description": "Connect Google Drive to find your files.",
        "status": "not_installed",
        "supported_auth_method": "app"
      },
      {
        "id": "6a213b5fe438b1a9f0629a6e",
        "code": "linear",
        "label": "Linear",
        "image_url": "https://cdn.autonomous.ai/assets/icons/linear_icon.png",
        "mcp_url": "https://mcp.linear.app/mcp",
        "description": "Manage issues and projects.",
        "order": 7,
        "status": "installed",
        "supported_auth_method": "app"
      },
      {
        "id": "6a213b5fe438b1a9f0629a73",
        "code": "gmail",
        "label": "Gmail",
        "description": "Search your messages.",
        "order": 1,
        "status": "not_installed",
        "supported_auth_method": "app"
      },
      { "id": "no-code", "label": "Missing its code" },
      "not even an object"
    ],
    "total": 27
  }
}
''';

void main() {
  group('parseConnectorCatalogResponse', () {
    test('reads the API envelope and drops unreadable rows', () {
      final entries = parseConnectorCatalogResponse(_apiResponse)!;
      expect(entries.map((e) => e.code), ['gmail', 'linear', 'google_drive']);
    });

    test('carries every field the row needs', () {
      final entries = parseConnectorCatalogResponse(_apiResponse)!;
      final linear = entries.firstWhere((e) => e.code == 'linear');
      expect(linear.id, '6a213b5fe438b1a9f0629a6e');
      expect(linear.label, 'Linear');
      expect(linear.description, 'Manage issues and projects.');
      expect(linear.imageUrl, endsWith('linear_icon.png'));
      expect(linear.mcpUrl, 'https://mcp.linear.app/mcp');
      expect(linear.order, 7);
      expect(linear.authMethod, ConnectorAuthMethod.app);
    });

    test('only the literal "not_installed" reads as not linked', () {
      final entries = parseConnectorCatalogResponse(_apiResponse)!;
      expect(entries.firstWhere((e) => e.code == 'linear').installed, isTrue);
      expect(entries.firstWhere((e) => e.code == 'gmail').installed, isFalse);
    });

    test('an entry with no order sorts after the ones that have it', () {
      final entries = parseConnectorCatalogResponse(_apiResponse)!;
      expect(entries.last.code, 'google_drive');
    });

    test('a body that is not a catalog reads as null, so the caller can fall '
        'back rather than blank the screen', () {
      expect(parseConnectorCatalogResponse('not json'), isNull);
      expect(parseConnectorCatalogResponse('{"status": 1}'), isNull);
      expect(parseConnectorCatalogResponse('{"data": {}}'), isNull);
      expect(parseConnectorCatalogResponse('[]'), isNull);
    });

    test('an empty catalog is a valid answer, not a failure', () {
      final entries = parseConnectorCatalogResponse(
        '{"status": 1, "data": {"connectors": [], "total": 0}}',
      );
      expect(entries, isNotNull);
      expect(entries, isEmpty);
    });
  });

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

  group('ConnectorCatalogClient', () {
    test('builds the endpoint with or without a trailing slash', () {
      expect(
        ConnectorCatalogClient.endpoint('https://api.example.com').toString(),
        'https://api.example.com/v1/connectors',
      );
      expect(
        ConnectorCatalogClient.endpoint('https://api.example.com/').toString(),
        'https://api.example.com/v1/connectors',
      );
    });

    test('signed out never reaches the network', () async {
      const client = ConnectorCatalogClient(
        apiUrl: 'https://api.example.com',
        sessionToken: null,
      );
      final (entries, error) = await client.fetch();
      expect(entries, isNull);
      expect(error?.message, 'Not signed in.');
    });
  });

  group('parseConnectorCatalog (bundled asset)', () {
    test('reads well-formed entries and drops unreadable ones', () {
      final catalog = parseConnectorCatalog('''
{
  "version": 1,
  "connectors": [
    {
      "id": "notion", "code": "notion", "label": "Notion",
      "description": "Pages and databases.",
      "image_url": "https://cdn.example/notion.png",
      "mcp": { "type": "http", "url": "https://mcp.notion.com/mcp" }
    },
    { "code": "broken" },
    "not even an object"
  ]
}
''');
      expect(catalog, hasLength(1));
      expect(catalog.single.code, 'notion');
      expect(catalog.single.label, 'Notion');
      expect(catalog.single.mcpUrl, 'https://mcp.notion.com/mcp');
      expect(catalog.single.imageUrl, 'https://cdn.example/notion.png');
    });

    test(
      'a catalog from a newer world reads as empty, not half-understood',
      () {
        expect(
          parseConnectorCatalog('{"version": 99, "connectors": []}'),
          isEmpty,
        );
      },
    );

    test('garbage reads as empty rather than throwing', () {
      expect(parseConnectorCatalog('not json'), isEmpty);
      expect(parseConnectorCatalog('[]'), isEmpty);
      expect(parseConnectorCatalog('{"version": "one"}'), isEmpty);
    });

    test('the bundled asset parses and is non-empty', () async {
      // Read the real file the app ships (tests run at the package root), so a
      // malformed edit to catalog.json fails here instead of silently emptying
      // the fallback — the provider swallows parse failures by design.
      final raw = await File('assets/connectors/catalog.json').readAsString();
      final catalog = parseConnectorCatalog(raw);
      expect(catalog, isNotEmpty);
      expect(catalog.map((e) => e.code), contains('notion'));
      // Every bundled entry carries a mark, so the fallback list looks like
      // the API list rather than a column of grey glyphs.
      expect(catalog.every((e) => e.imageUrl.isNotEmpty), isTrue);
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
