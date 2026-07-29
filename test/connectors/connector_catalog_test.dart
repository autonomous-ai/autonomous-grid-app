import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/connector_token.dart';
import 'package:grid_app/features/agents/logic/mcp_server.dart';
import 'package:grid_app/features/connectors/logic/connector.dart';
import 'package:grid_app/features/connectors/logic/connector_catalog.dart';
import 'package:grid_app/infrastructure/api/connector_gateway_client.dart';

/// Verbatim from `GET /v1/grid/connectors` on staging, 2026-07-29.
///
/// The envelope is what this pins: the body is a flat `{"connectors": [...]}`,
/// **not** `{"data": {"connectors": [...]}}`. A parser expecting the wrapped
/// form reads this as "not a catalog at all", falls back to the bundled asset,
/// and the screen quietly shows eight hardcoded rows while the gateway is
/// offering sixteen. That is exactly what shipped, and it looked like a backend
/// with nothing ready rather than like a parsing bug.
const _gatewayResponse = '''
{"connectors": [
  {"code": "amplitude", "auth_type": "app", "scopes": ["a", "b", "c"],
   "refresh": true, "mcp_url": "https://mcp.amplitude.com/mcp",
   "mcp_ready": true, "status": "not_connected", "account_name": "",
   "expires_at": 0, "connected_at": 0},
  {"code": "asana", "auth_type": "app", "scopes": [],
   "refresh": true, "mcp_url": "https://mcp.asana.com/v2/mcp",
   "mcp_ready": true, "status": "not_connected", "account_name": "",
   "expires_at": 0, "connected_at": 0}
]}
''';

void main() {
  group('the gateway catalog feeds the two Connect gates', () {
    test('mcp_ready survives the parse', () {
      // The whole screen hangs off this one flag: without it every row reads
      // "No tools available for this connector yet" and Connect never appears.
      final entries = parseGatewayConnectors(_gatewayResponse)!;
      expect(entries.map((e) => e.code), ['amplitude', 'asana']);
      expect(entries.every((e) => e.mcpReady), isTrue);
      expect(entries.every((e) => e.canConnectFromApp), isTrue);
    });

    test('the envelope is flat, and the wrapped form is not a catalog', () {
      expect(
        parseGatewayConnectors('{"data": {"connectors": []}}'),
        isNull,
        reason: 'the wrapped shape must not read as an empty catalog',
      );
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

  group('mergeCatalog', () {
    const bundledGmail = ConnectorCatalogEntry(
      id: 'gmail',
      code: 'gmail',
      label: 'Gmail',
      description: 'Search your messages.',
      imageUrl: 'https://cdn.example/gmail.png',
    );

    test('the gateway supplies the rows, the asset supplies the words', () {
      // The gateway sends no label, description or image_url for any row today,
      // so without this merge the screen reads as a list of slugs.
      final merged = mergeCatalog(
        remote: parseGatewayConnectors(
          '{"connectors": [{"code": "gmail", "auth_type": "pat"}]}',
        )!,
        bundled: const [bundledGmail],
      );
      expect(merged.single.label, 'Gmail');
      expect(merged.single.imageUrl, 'https://cdn.example/gmail.png');
    });

    test('state always comes from the gateway, never from the asset', () {
      // The bundled entry defaults to mcpReady false / authMethod app. If the
      // merge let it win, a live connector would look unavailable — and a stale
      // shipped asset would outrank the backend.
      final merged = mergeCatalog(
        remote: parseGatewayConnectors(
          '{"connectors": [{"code": "gmail", "auth_type": "pat", '
          '"mcp_ready": true, "status": "connected"}]}',
        )!,
        bundled: const [bundledGmail],
      );
      expect(merged.single.mcpReady, isTrue);
      expect(merged.single.linkedAtServer, isTrue);
      expect(merged.single.authMethod, ConnectorAuthMethod.manual);
    });

    test('a connector the asset never heard of still gets a name', () {
      // The gateway's list grows on its own schedule; amplitude and asana are
      // already on it and in no shipped asset.
      final merged = mergeCatalog(
        remote: parseGatewayConnectors(
          '{"connectors": [{"code": "gmail-app"}, {"code": "amplitude"}]}',
        )!,
        bundled: const [bundledGmail],
      );
      expect(merged.map((e) => e.label), ['Amplitude', 'Gmail App']);
      expect(merged.every((e) => e.imageUrl.isEmpty), isTrue);
    });

    test('codes are matched exactly, never by prefix', () {
      // `gmail` and `gmail-app` are two rows on the wire with different
      // auth_type. Treating them as one service puts one's icon on the other.
      final merged = mergeCatalog(
        remote: parseGatewayConnectors(
          '{"connectors": [{"code": "gmail-app"}]}',
        )!,
        bundled: const [bundledGmail],
      );
      expect(merged.single.label, 'Gmail App');
      expect(merged.single.imageUrl, isEmpty);
    });
  });

  group('labelFromCode', () {
    test('turns a slug into a phrase', () {
      expect(labelFromCode('google_calendar'), 'Google Calendar');
      expect(labelFromCode('gmail-app'), 'Gmail App');
      expect(labelFromCode('hubspot'), 'Hubspot');
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

    test('a token on this machine reads as connected before the server', () {
      // The state right after a successful sign-in: the credential is stored,
      // the projection into the agent's config has not landed yet. Waiting for
      // the server would leave the row under "Available" and read as failure.
      final connectors = buildConnectors(
        servers: const [],
        catalog: const [notion],
        tokens: {
          'notion': ConnectorToken(
            connector: 'notion',
            accessToken: 'tok',
            mcpEntry: const McpEntry(url: 'https://mcp.notion.com/mcp'),
          ),
        },
      );
      expect(connectors.single.connected, isTrue);
      expect(connectors.single.token, isNotNull);
    });

    test("the gateway's own status does not make a row connected", () {
      // linkedAtServer means the account is linked somewhere — possibly another
      // computer. This agent still has nothing to call, so the row stays under
      // Available and explains itself instead (D6).
      const linkedElsewhere = ConnectorCatalogEntry(
        id: 'notion',
        code: 'notion',
        label: 'Notion',
        description: '',
        linkedAtServer: true,
      );
      final connectors = buildConnectors(
        servers: const [],
        catalog: const [linkedElsewhere],
      );
      expect(connectors.single.connected, isFalse);
      expect(connectors.single.linkedElsewhere, isTrue);
    });

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
