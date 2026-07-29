import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/connectors/logic/connector_catalog.dart';
import 'package:grid_app/infrastructure/api/connector_gateway_client.dart';

void main() {
  group('parseGatewayConnectors', () {
    const body = '''
{"connectors": [
  {"code": "linear", "auth_type": "app", "scopes": ["read", "write"],
   "refresh": true, "mcp_url": "https://mcp.linear.app/mcp", "mcp_ready": true,
   "status": "connected", "account_name": "Khanh Cao",
   "expires_at": 1785312000, "connected_at": 1785308400},
  {"code": "notion", "auth_type": "app", "refresh": true,
   "mcp_url": "https://mcp.notion.com/mcp", "mcp_ready": true,
   "status": "not_connected", "account_name": "", "expires_at": 0},
  {"code": "google_drive", "auth_type": "app", "mcp_ready": false,
   "status": "not_connected"},
  {"code": "github", "auth_type": "pat", "mcp_ready": true,
   "status": "not_connected"},
  {"auth_type": "app"},
  "not even an object"
]}
''';

    test('reads every field the row needs', () {
      final linear = parseGatewayConnectors(
        body,
      )!.firstWhere((e) => e.code == 'linear');
      expect(linear.authMethod, ConnectorAuthMethod.app);
      expect(linear.mcpReady, isTrue);
      expect(linear.mcpUrl, 'https://mcp.linear.app/mcp');
      expect(linear.linkedAtServer, isTrue);
      expect(linear.accountName, 'Khanh Cao');
      expect(linear.canRefresh, isTrue);
    });

    test('only the literal "connected" counts as linked at the server', () {
      final entries = parseGatewayConnectors(body)!;
      expect(
        entries.firstWhere((e) => e.code == 'notion').linkedAtServer,
        isFalse,
      );
    });

    test('a row with no code is dropped, the rest still show', () {
      expect(parseGatewayConnectors(body)!.map((e) => e.code), [
        'github',
        'google_drive',
        'linear',
        'notion',
      ]);
    });

    group('the two gates on Connect', () {
      test('a pat connector cannot be connected from the app', () {
        // There is no flow to call — the user has to paste a token by hand — so
        // the button must never be offered, not merely fail when pressed.
        final github = parseGatewayConnectors(
          body,
        )!.firstWhere((e) => e.code == 'github');
        expect(github.authMethod, ConnectorAuthMethod.manual);
        expect(github.canConnectFromApp, isFalse);
      });

      test('a connector with no MCP server cannot be connected either', () {
        // OAuth would genuinely succeed and the agent would still have nothing
        // to call. Five connectors are in this state today.
        final drive = parseGatewayConnectors(
          body,
        )!.firstWhere((e) => e.code == 'google_drive');
        expect(drive.mcpReady, isFalse);
        expect(drive.canConnectFromApp, isFalse);
      });

      test('both gates open means Connect is offered', () {
        final notion = parseGatewayConnectors(
          body,
        )!.firstWhere((e) => e.code == 'notion');
        expect(notion.canConnectFromApp, isTrue);
      });
    });

    group('the -pat twins are dropped', () {
      test('a -pat row never reaches the screen', () {
        // The gateway lists gmail, gmail-app and gmail-pat side by side. The
        // last one has no flow the app can drive, so it would render as a row
        // that says it is unavailable and offers nothing to press.
        final entries = parseGatewayConnectors(
          '{"connectors": [{"code": "gmail-pat"}, {"code": "gmail-app"}, '
          '{"code": "atlassian-pat"}]}',
        )!;
        expect(entries.map((e) => e.code), ['gmail-app']);
      });

      test('a plain pat connector stays', () {
        // `gmail` is auth_type pat too, but it is the row a user looks for by
        // name — so the rule is the code suffix, not the auth type.
        final entries = parseGatewayConnectors(
          '{"connectors": [{"code": "gmail", "auth_type": "pat"}]}',
        )!;
        expect(entries.single.code, 'gmail');
      });

      test('only the suffix counts, not the letters anywhere in the code', () {
        // "patreon" and "pat" would both fall to a `contains` check, and a
        // bare "pat" has no separator to make it a variant of anything.
        expect(isPatVariantCode('patreon'), isFalse);
        expect(isPatVariantCode('pat'), isFalse);
        expect(isPatVariantCode('gmail-pat'), isTrue);
        expect(isPatVariantCode('GMAIL-PAT'), isTrue);
      });
    });

    test('an unreadable body is null so the caller can fall back', () {
      // Null and [] are different answers: one is "we could not find out", the
      // other is "you have no connectors".
      expect(parseGatewayConnectors('not json'), isNull);
      expect(parseGatewayConnectors('{}'), isNull);
      expect(parseGatewayConnectors('{"connectors": []}'), isEmpty);
    });
  });

  group('parseAuthorization', () {
    const body = '''
{"connector": "linear",
 "authorize_url": "https://linear.app/oauth/authorize?client_id=3fb060cc",
 "pickup_code": "F7QH-2M4T", "poll_interval": 2, "expires_in": 600}
''';

    test('carries the URL and the pickup ticket', () {
      final auth = parseAuthorization(body, fallbackConnector: 'linear')!;
      expect(auth.authorizeUrl, startsWith('https://linear.app/oauth/'));
      expect(auth.pickupCode, 'F7QH-2M4T');
      expect(auth.pollInterval, const Duration(seconds: 2));
      expect(auth.expiresIn, const Duration(minutes: 10));
    });

    test('missing either handle reads as null', () {
      // No URL means nothing to open; no pickup code means no way to collect
      // the result once the user finishes.
      expect(
        parseAuthorization('{"pickup_code": "X"}', fallbackConnector: 'linear'),
        isNull,
      );
      expect(
        parseAuthorization(
          '{"authorize_url": "https://x"}',
          fallbackConnector: 'linear',
        ),
        isNull,
      );
      expect(parseAuthorization('not json', fallbackConnector: 'l'), isNull);
    });

    test('an absurd poll interval is clamped, never obeyed literally', () {
      // Zero would spin the loop; an hour would look broken.
      final fast = parseAuthorization(
        '{"authorize_url": "https://x", "pickup_code": "p", "poll_interval": 0}',
        fallbackConnector: 'linear',
      )!;
      expect(fast.pollInterval, const Duration(seconds: 1));
    });
  });

  group('parsePollResult', () {
    test('pending carries no token', () {
      final result = parsePollResult(
        '{"status": "pending", "connector": "linear", "error": ""}',
        fallbackConnector: 'linear',
      )!;
      expect(result.status, ConnectorPollStatus.pending);
      expect(result.token, isNull);
    });

    test('ready carries the token and the rendered MCP entry', () {
      final result = parsePollResult('''
{"status": "ready", "connector": "linear",
 "access_token": "lin_oauth_8f3d", "refresh_token": "lin_ref_2b91",
 "token_type": "Bearer", "expires_at": 1785312000, "scope": "read write",
 "account_name": "Khanh Cao",
 "mcp_entry": {"url": "https://mcp.linear.app/mcp",
   "headers": {"Authorization": "Bearer lin_oauth_8f3d"},
   "_grid": {"connector": "linear", "expires_at": 1785312000, "refresh": true}}}
''', fallbackConnector: 'linear')!;

      final token = result.token!;
      expect(token.accessToken, 'lin_oauth_8f3d');
      expect(token.refreshToken, 'lin_ref_2b91');
      expect(token.accountName, 'Khanh Cao');
      expect(
        token.expiresAt,
        DateTime.fromMillisecondsSinceEpoch(1785312000000),
      );
      expect(token.mcpEntry!.url, 'https://mcp.linear.app/mcp');
      expect(token.mcpEntry!.canRefresh, isTrue);
      expect(token.isUsable, isTrue);
    });

    test('ready with a null mcp_entry is still a real sign-in', () {
      // Five connectors are OAuth-capable with no MCP server. The account links
      // for real; the agent just has nothing to call.
      final result = parsePollResult('''
{"status": "ready", "connector": "google_drive",
 "access_token": "ya29.a0Af", "expires_at": 1785312000, "mcp_entry": null}
''', fallbackConnector: 'google_drive')!;

      expect(result.token, isNotNull);
      expect(result.token!.accessToken, 'ya29.a0Af');
      expect(result.token!.isUsable, isFalse);
    });

    test('every failure is also HTTP 200 — status is the only signal', () {
      for (final (raw, expected) in [
        ('failed', ConnectorPollStatus.failed),
        ('expired', ConnectorPollStatus.expired),
        ('consumed', ConnectorPollStatus.consumed),
      ]) {
        final result = parsePollResult(
          '{"status": "$raw", "connector": "linear", "error": "boom"}',
          fallbackConnector: 'linear',
        )!;
        expect(result.status, expected);
        expect(result.token, isNull);
      }
    });

    test('an unknown status reads as null, never as success', () {
      // Guessing "pending" would poll forever; guessing "ready" would claim a
      // token that isn't there.
      expect(
        parsePollResult(
          '{"status": "quantum", "connector": "linear"}',
          fallbackConnector: 'linear',
        ),
        isNull,
      );
    });
  });

  group('parseTokenPayload (refresh)', () {
    test('reads the renewed token and its new entry', () {
      final token = parseTokenPayload('''
{"status": "ok", "connector": "linear", "access_token": "lin_oauth_NEW",
 "token_type": "Bearer", "expires_at": 1785315600,
 "mcp_entry": {"url": "https://mcp.linear.app/mcp",
   "headers": {"Authorization": "Bearer lin_oauth_NEW"},
   "_grid": {"connector": "linear", "expires_at": 1785315600, "refresh": true}}}
''', fallbackConnector: 'linear')!;

      expect(token.accessToken, 'lin_oauth_NEW');
      expect(token.mcpEntry!.bearerToken, 'lin_oauth_NEW');
    });
  });

  group('parseDetail', () {
    test("shows the gateway's own sentence, which is written for a person", () {
      expect(
        parseDetail('{"detail": "Unsupported connector \'xyz\'"}'),
        "Unsupported connector 'xyz'",
      );
    });

    test('a body with no detail falls back to the status code', () {
      expect(parseDetail('{"other": "thing"}'), isNull);
      expect(parseDetail('<html>404</html>'), isNull);
    });
  });

  group('ConnectorGatewayClient', () {
    test('every path sits under /v1/grid', () {
      expect(
        ConnectorGatewayClient.endpoint(
          'https://api-grid.autonomous.ai',
          'connectors/start',
        ).toString(),
        'https://api-grid.autonomous.ai/v1/grid/connectors/start',
      );
      expect(
        ConnectorGatewayClient.endpoint(
          'https://api-grid.autonomous.ai/',
          'connectors',
        ).toString(),
        'https://api-grid.autonomous.ai/v1/grid/connectors',
      );
    });

    test('signed out never reaches the network', () async {
      const client = ConnectorGatewayClient(
        apiUrl: 'https://api.example.com',
        sessionToken: null,
      );
      final (auth, error) = await client.start('linear');
      expect(auth, isNull);
      expect(error?.message, 'Not signed in.');
    });

    test('an unreachable grid says so, rather than failing silently', () async {
      const client = ConnectorGatewayClient(
        apiUrl: 'http://127.0.0.1:1/',
        sessionToken: 'token',
        timeout: Duration(milliseconds: 300),
      );
      final (auth, error) = await client.start('linear');
      expect(auth, isNull);
      expect(error!.message, contains("Couldn't reach the grid"));
    });
  });
}
