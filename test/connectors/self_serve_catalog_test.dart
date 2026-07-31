import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/connectors/logic/connector_catalog.dart';
import 'package:grid_app/features/connectors/logic/self_serve_catalog.dart';

void main() {
  group('parseSelfServeCatalog', () {
    test('reads a row and marks it self-serve', () {
      final entries = parseSelfServeCatalog('''
{"connectors": [
  {"code": "canva", "label": "Canva", "description": "Designs.",
   "mcp_url": "https://mcp.canva.com/mcp",
   "image_url": "https://icons.example/canva.png"}
]}''');
      final canva = entries.single;
      expect(canva.code, 'canva');
      expect(canva.label, 'Canva');
      expect(canva.mcpUrl, 'https://mcp.canva.com/mcp');
      expect(canva.imageUrl, 'https://icons.example/canva.png');
      expect(canva.authMethod, ConnectorAuthMethod.dcr);
      // The Connect button reads this, and it is the whole point of the row.
      expect(canva.canConnectFromApp, isTrue);
    });

    test('never leaves a row without a mark', () {
      // An available row takes `image_url` verbatim — there is no favicon
      // fallback on that side — so an empty mark here would show a glyph under
      // Available and the brand's logo under Connected.
      final entry = parseSelfServeCatalog(
        '{"connectors": [{"code": "canva", "mcp_url": '
        '"https://mcp.canva.com/mcp"}]}',
      ).single;
      expect(entry.imageUrl, contains('canva.com'));
      // Asked about the apex, not the MCP subdomain: `mcp.*` serves no favicon.
      expect(entry.imageUrl, isNot(contains('mcp.canva.com')));
    });

    test('claims nothing about the user account at the gateway', () {
      // `linkedAtServer` is what `Connector.needsSignInHere` reads. True here
      // would put "connected to your account, but not on this computer" under a
      // row no account was ever linked to.
      final entry = parseSelfServeCatalog(
        '{"connectors": [{"code": "canva", "mcp_url": "https://mcp.canva.com/mcp"}]}',
      ).single;
      expect(entry.linkedAtServer, isFalse);
      expect(entry.installed, isFalse);
      expect(entry.accountName, isEmpty);
      // There *is* a server to call once signed in, and this says so.
      expect(entry.mcpReady, isTrue);
    });

    test('names a row the file left unlabelled', () {
      final entry = parseSelfServeCatalog(
        '{"connectors": [{"code": "google_drive", "mcp_url": "https://x/mcp"}]}',
      ).single;
      expect(entry.label, 'Google Drive');
    });

    test('skips a row with no server to connect to, keeping the others', () {
      final entries = parseSelfServeCatalog('''
{"connectors": [
  {"code": "nowhere", "label": "Nowhere"},
  {"code": "canva", "mcp_url": "https://mcp.canva.com/mcp"}
]}''');
      expect(entries.map((e) => e.code), ['canva']);
    });

    test('a file that will not parse is an empty list, not a throw', () {
      // The gateway's catalog awaits this one. A bundled file gone wrong must
      // not take sixteen working connectors down with it.
      expect(parseSelfServeCatalog('not json'), isEmpty);
      expect(parseSelfServeCatalog('[]'), isEmpty);
      expect(parseSelfServeCatalog('{}'), isEmpty);
      expect(parseSelfServeCatalog('{"connectors": {}}'), isEmpty);
    });
  });

  group('mergeCatalog', () {
    const bundled = ConnectorCatalogEntry(
      id: 'canva',
      code: 'canva',
      label: 'Canva',
      description: 'From the bundled file.',
      mcpUrl: 'https://mcp.canva.com/mcp',
      authMethod: ConnectorAuthMethod.dcr,
    );

    test('adds a self-serve row the gateway does not publish', () {
      const notion = ConnectorCatalogEntry(
        id: 'notion',
        code: 'notion',
        label: 'Notion',
        description: '',
      );
      final merged = mergeCatalog(
        gateway: const [notion],
        selfServe: const [bundled],
      );
      expect(merged.map((e) => e.code), ['canva', 'notion']);
    });

    test('a gateway row of the same code wins', () {
      // The handover: once the backend publishes Canva, its row — with its own
      // blurb, logo and account status — replaces the bundled one, and this
      // file needs no edit for that to happen.
      const fromGateway = ConnectorCatalogEntry(
        id: 'canva',
        code: 'canva',
        label: 'Canva',
        description: 'From the gateway.',
        authMethod: ConnectorAuthMethod.app,
      );
      final merged = mergeCatalog(
        gateway: const [fromGateway],
        selfServe: const [bundled],
      );
      expect(merged, hasLength(1));
      expect(merged.single.description, 'From the gateway.');
      expect(merged.single.authMethod, ConnectorAuthMethod.app);
    });

    test('an unreachable gateway still leaves the self-serve rows', () {
      // Nothing in their sign-in goes through the grid, so being unable to
      // reach it is no reason to hide them.
      final merged = mergeCatalog(
        gateway: const [],
        selfServe: const [bundled],
      );
      expect(merged.single.code, 'canva');
    });
  });

  group('auth', () {
    ConnectorCatalogEntry parseOne(String auth) => parseSelfServeCatalog(
      '{"connectors": [{"code": "x", "mcp_url": "https://x/mcp"'
      '${auth.isEmpty ? '' : ', "auth": "$auth"'}}]}',
    ).single;

    test('defaults to dcr', () {
      expect(parseOne('').authMethod, ConnectorAuthMethod.dcr);
    });

    test('reads open', () {
      expect(parseOne('open').authMethod, ConnectorAuthMethod.open);
    });

    test('an unknown value falls to dcr rather than dropping the row', () {
      // It still gets probed, and the probe is what actually decides.
      expect(parseOne('device_code').authMethod, ConnectorAuthMethod.dcr);
    });

    test('both kinds offer Connect', () {
      expect(parseOne('').canConnectFromApp, isTrue);
      expect(parseOne('open').canConnectFromApp, isTrue);
      expect(parseOne('').isSelfServe, isTrue);
      expect(parseOne('open').isSelfServe, isTrue);
    });
  });

  group('the shipped asset', () {
    // Read through the real bundle: a JSON file that parses in isolation but
    // was never declared in `pubspec.yaml` would fail only at runtime, as a
    // connectors screen quietly missing its rows.
    Future<List<ConnectorCatalogEntry>> shipped() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      return parseSelfServeCatalog(
        await rootBundle.loadString(kSelfServeCatalogAsset),
      );
    }

    test('parses, and offers Canva as a connectable row', () async {
      final canva = (await shipped()).firstWhere((e) => e.code == 'canva');
      expect(canva.label, 'Canva');
      expect(canva.mcpUrl, 'https://mcp.canva.com/mcp');
      expect(canva.canConnectFromApp, isTrue);
      expect(canva.imageUrl, isNotEmpty);
    });

    test('every row is connectable and names a server', () async {
      for (final entry in await shipped()) {
        expect(entry.canConnectFromApp, isTrue, reason: entry.code);
        expect(entry.mcpUrl, startsWith('https://'), reason: entry.code);
        expect(entry.label, isNotEmpty, reason: entry.code);
        expect(entry.description, isNotEmpty, reason: entry.code);
      }
    });

    test('no row duplicates a connector the gateway already owns', () async {
      // The twelve in `grid-apis-v2/data/config-connector-auth.prod.json`.
      // `mergeCatalog` would drop a collision anyway, so a row here that
      // collides is dead weight shipped in the binary — and a sign somebody
      // added it without checking the backend.
      const gatewayOwned = {
        'google_drive',
        'gmail',
        'google_calendar',
        'slack',
        'notion',
        'asana',
        'linear',
        'figma-api-app',
        'amplitude',
        'github',
        'hubspot',
        'mondaydotcom',
      };
      for (final entry in await shipped()) {
        expect(gatewayOwned, isNot(contains(entry.code)), reason: entry.code);
      }
    });

    test('the servers measured as unusable stay off the list', () async {
      // Each was probed on 2026-07-31 and rejected for its own reason; the
      // file's `_comment` records which. They are pinned here because every one
      // of them *looks* fine from the outside — a row for any would offer a
      // Connect button that cannot end in working tools.
      final codes = (await shipped()).map((e) => e.code);
      for (final rejected in const [
        'figma', // registration_endpoint advertised, POST answers 403
        'box', // no registration_endpoint at all
        'booking', // 403 with no WWW-Authenticate, per-account URL
        'bigquery', // handshake open, tools/call demands Google credentials
        'browserbase', // handshake open, needs ?apiKey= in the URL
      ]) {
        expect(codes, isNot(contains(rejected)), reason: rejected);
      }
    });

    test('Cloudflare is the one unified server, not a sub-server', () async {
      final cloudflare = (await shipped()).where(
        (e) => e.mcpUrl.contains('cloudflare'),
      );
      expect(cloudflare, hasLength(1));
      expect(cloudflare.single.mcpUrl, 'https://mcp.cloudflare.com/mcp');
    });
  });
}
