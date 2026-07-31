import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/connector_token.dart';
import 'package:grid_app/features/connectors/logic/dcr_client_store.dart';
import 'package:grid_app/features/connectors/logic/dcr_oauth_client.dart';
import 'package:grid_app/features/connectors/logic/mcp_auth_probe.dart';

/// The shape of a token path A hands to the store.
///
/// Every assertion here is about a field that is invisible until an hour later.
/// A wrong `issuer` or a missing `source` does not fail the sign-in — it fails
/// the *renewal*, and reports itself as "that connection expired" next to a
/// perfectly good refresh token. That gap is why these are pinned.
void main() {
  late Directory home;
  late DcrOAuthClient client;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('grid_dcr_shape');
    client = DcrOAuthClient(store: DcrClientStore(home: home));
  });
  tearDown(() => home.delete(recursive: true));

  const probe = McpAuthProbeResult(
    kind: McpAuthKind.dynamicRegistration,
    issuer: 'https://api.supabase.com',
    authorizationEndpoint: 'https://api.supabase.com/v1/oauth/authorize',
    tokenEndpoint: 'https://api.supabase.com/v1/oauth/token',
    registrationEndpoint:
        'https://api.supabase.com/platform/oauth/apps/register',
    resource: 'https://mcp.supabase.com/mcp',
    supportsS256: true,
  );

  Map<String, dynamic> payload({
    String? refreshToken = 'refresh-me',
    int? expiresIn = 3600,
  }) => {
    'access_token': 'sbp_oauth_abc',
    'token_type': 'Bearer',
    'refresh_token': ?refreshToken,
    'expires_in': ?expiresIn,
    'scope': 'projects:read',
  };

  group('a token from a sign-in', () {
    test('carries the issuer, or it can never be renewed', () async {
      // The bug this pins. `exchange` built the token without an issuer, so the
      // store held `source: dcr` with nothing saying *which* authorization
      // server — and `refresh` looks the registration up by exactly that. Two
      // real connectors were written that way on 2026-07-30.
      final (token, error) = client.tokenFrom(
        payload(),
        connector: 'Supabase',
        mcpUrl: 'https://mcp.supabase.com/mcp',
        issuer: probe.issuer,
      );

      expect(error, isNull);
      expect(token!.issuer, 'https://api.supabase.com');
      expect(token.source, ConnectorTokenSource.dcr);
    });

    test('records at the top level that it can be renewed', () async {
      // Not only inside `mcp_entry._grid`. The entry is optional — a connector
      // with no MCP server still holds an expiring credential — and a store
      // where gateway rows carry `"refresh": true` while self-registered ones
      // carry nothing reads as though the second kind cannot renew at all.
      final (token, _) = client.tokenFrom(
        payload(),
        connector: 'Supabase',
        mcpUrl: 'https://mcp.supabase.com/mcp',
        issuer: probe.issuer,
      );

      expect(token!.canRefresh, isTrue);
      expect(token.toJson()['refresh'], isTrue);
      // The copy inside the entry still agrees with it.
      expect(token.mcpEntry!.canRefresh, isTrue);
    });

    test('says so at the top level when it cannot be renewed', () async {
      final (token, _) = client.tokenFrom(
        payload(refreshToken: null),
        connector: 'Supabase',
        mcpUrl: 'https://mcp.supabase.com/mcp',
        issuer: probe.issuer,
      );

      expect(token!.canRefresh, isFalse);
      expect(token.toJson()['refresh'], isFalse);
      expect(token.canBeRefreshed, isFalse);
    });

    test('records renewal even with no MCP entry to hold a copy', () async {
      // The case the top-level field exists for: `mcpEntry` is null, so the
      // `_grid.refresh` copy does not exist, and the old inference off
      // `refresh_token` was the only thing left.
      final (token, _) = client.tokenFrom(
        payload(),
        connector: 'Supabase',
        mcpUrl: '',
        issuer: probe.issuer,
      );

      expect(token!.mcpEntry, isNull);
      expect(token.canRefresh, isTrue);
      expect(token.canBeRefreshed, isTrue);
    });

    test('is marked dcr, so the gateway is never asked about it', () async {
      // Calling the gateway's /refresh for a self-registered connector asks it
      // about a credential it has never seen.
      final (token, _) = client.tokenFrom(
        payload(),
        connector: 'Supabase',
        mcpUrl: 'https://mcp.supabase.com/mcp',
        issuer: probe.issuer,
      );

      expect(token!.source, ConnectorTokenSource.dcr);
    });

    test('renders an mcp_entry the agent can use', () async {
      final (token, _) = client.tokenFrom(
        payload(),
        connector: 'Supabase',
        mcpUrl: 'https://mcp.supabase.com/mcp',
        issuer: probe.issuer,
      );

      // Path A has no server to render this, so the app does — in the same shape
      // the gateway produces, which is what lets everything downstream treat the
      // two paths identically.
      expect(token!.mcpEntry!.url, 'https://mcp.supabase.com/mcp');
      expect(token.mcpEntry!.headers['Authorization'], 'Bearer sbp_oauth_abc');
      expect(token.isUsable, isTrue);
    });

    test('is refreshable only when the provider issued a refresh token', () {
      final (with_, _) = client.tokenFrom(
        payload(),
        connector: 'a',
        mcpUrl: 'https://x/mcp',
        issuer: probe.issuer,
      );
      final (without, _) = client.tokenFrom(
        payload(refreshToken: null),
        connector: 'b',
        mcpUrl: 'https://x/mcp',
        issuer: probe.issuer,
      );

      // Without the second half, a renewal only spends a request.
      expect(with_!.canBeRefreshed, isTrue);
      expect(without!.canBeRefreshed, isFalse);
    });

    test('turns a relative expiry into an absolute instant', () {
      // `expires_in` is meaningless once written to disk: after a restart there
      // is nothing left to measure it from.
      final (token, _) = client.tokenFrom(
        payload(expiresIn: 3600),
        connector: 'a',
        mcpUrl: 'https://x/mcp',
        issuer: probe.issuer,
      );

      expect(token!.expiresAt, isNotNull);
      expect(token.isExpired(), isFalse);
    });

    test('a payload with no access token is an error, not an empty token', () {
      final (token, error) = client.tokenFrom(
        {'token_type': 'Bearer'},
        connector: 'a',
        mcpUrl: 'https://x/mcp',
        issuer: probe.issuer,
      );

      expect(token, isNull);
      expect(error, isNotNull);
    });
  });

  group('registration is refused before anything is written', () {
    test('a server without S256 is turned away', () async {
      // Two of three servers measured also offer `plain`, which is PKCE with the
      // protection removed. Proceeding on it would be a silent downgrade.
      final (registered, error) = await client.register(
        const McpAuthProbeResult(
          kind: McpAuthKind.dynamicRegistration,
          issuer: 'https://weak.example',
          authorizationEndpoint: 'https://weak.example/authorize',
          tokenEndpoint: 'https://weak.example/token',
          registrationEndpoint: 'https://weak.example/register',
          supportsS256: false,
        ),
        redirectUri: 'http://127.0.0.1:51789/callback',
      );

      expect(registered, isNull);
      expect(error!.message, contains('PKCE'));
      // Nothing was stored, so a later attempt against a fixed server starts
      // clean rather than reusing a half-made registration.
      expect(await DcrClientStore(home: home).read(), isEmpty);
    });

    test('a server needing a pre-registered app is turned away', () async {
      final (registered, error) = await client.register(
        const McpAuthProbeResult(
          kind: McpAuthKind.preRegistered,
          issuer: 'https://google.example',
          authorizationEndpoint: 'https://google.example/authorize',
          tokenEndpoint: 'https://google.example/token',
          supportsS256: true,
        ),
        redirectUri: 'http://127.0.0.1:51789/callback',
      );

      expect(registered, isNull);
      expect(error, isNotNull);
    });
  });
}
