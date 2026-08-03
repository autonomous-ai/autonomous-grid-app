import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/connector_token.dart';
import 'package:grid_app/features/connectors/logic/connector_token_store.dart';

void main() {
  late Directory home;
  late ConnectorTokenStore store;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('grid_connector_tokens');
    store = ConnectorTokenStore(home: home);
  });
  tearDown(() => home.delete(recursive: true));

  ConnectorToken token(String connector, {DateTime? expiresAt}) {
    return ConnectorToken(
      connector: connector,
      accessToken: 'access-$connector',
      refreshToken: 'refresh-$connector',
      expiresAt: expiresAt,
      scope: 'read write',
      mcpEntry: McpEntry(
        url: 'https://mcp.example/$connector',
        headers: {'Authorization': 'Bearer access-$connector'},
        canRefresh: true,
      ),
    );
  }

  group('reading a store that is not there yet', () {
    test('a missing file is an empty store, not a failure', () async {
      expect(await store.read(), isEmpty);
    });

    test(
      'a file that will not parse reads as empty rather than throwing',
      () async {
        // Refusing to start over one bad byte would lock the user out of the very
        // screen that could fix it. The next write replaces the file.
        await store.directory.create(recursive: true);
        await store.file.writeAsString('not json at all');
        expect(await store.read(), isEmpty);
      },
    );

    test(
      'an entry with no access token is dropped, the rest survive',
      () async {
        await store.directory.create(recursive: true);
        await store.file.writeAsString(
          jsonEncode({
            'broken': {'scope': 'read'},
            'gmail': {'access_token': 'live'},
          }),
        );
        final tokens = await store.read();
        expect(tokens.keys, ['gmail']);
      },
    );
  });

  group('round trip', () {
    test('every field survives a write and a read', () async {
      final expiry = DateTime.fromMillisecondsSinceEpoch(1785000000 * 1000);
      await store.save(token('gmail', expiresAt: expiry));

      final read = (await store.read())['gmail']!;
      expect(read.connector, 'gmail');
      expect(read.accessToken, 'access-gmail');
      expect(read.refreshToken, 'refresh-gmail');
      expect(read.scope, 'read write');
      expect(read.mcpEntry!.url, 'https://mcp.example/gmail');
      expect(read.mcpEntry!.canRefresh, isTrue);
      // The rendered entry survives the round trip: it is the only record of
      // how this provider expects to be addressed.
      expect(read.mcpEntry!.bearerToken, 'access-gmail');
      expect(read.tokenType, 'Bearer');
      // Stored as whole seconds, so compare at that resolution.
      expect(read.expiresAt, expiry);
    });

    test('saving one connector leaves the others alone', () async {
      await store.save(token('gmail'));
      await store.save(token('slack'));
      expect((await store.read()).keys, containsAll(['gmail', 'slack']));

      await store.save(
        ConnectorToken(connector: 'gmail', accessToken: 'rotated'),
      );
      final tokens = await store.read();
      expect(tokens['gmail']!.accessToken, 'rotated');
      expect(tokens['slack']!.accessToken, 'access-slack');
    });

    test(
      'remove takes one out and is a no-op for one that is not there',
      () async {
        await store.save(token('gmail'));
        await store.remove('slack');
        expect((await store.read()).keys, ['gmail']);

        await store.remove('gmail');
        expect(await store.read(), isEmpty);
      },
    );
  });

  group('the auth scheme a stored entry carries', () {
    /// Reads an entry straight out of the wire shape, which is where the repair
    /// happens — the store hands these to every agent projection.
    McpEntry entryWith(String authorization) => McpEntry.fromJson({
      'url': 'https://mcp.canva.com/mcp',
      'headers': {'Authorization': authorization},
    })!;

    test('a lowercase bearer is repaired on read', () async {
      // Measured 2026-08-03: canva, cloudflare and postman each answer
      // `token_type: "bearer"`, the app copied that into the header verbatim,
      // and all three then refused their own spelling — 401 on `bearer …`, 200
      // on `Bearer …`, with hours left on the credential. It reported itself as
      // "the OAuth token expired".
      //
      // Repaired on *read* so an entry already on disk is fixed at the next
      // projection, rather than waiting for its own renewal to rewrite it.
      expect(
        entryWith('bearer sbp_abc').headers['Authorization'],
        'Bearer sbp_abc',
      );
    });

    test('a correct header is left exactly as it was', () async {
      expect(
        entryWith('Bearer sbp_abc').headers['Authorization'],
        'Bearer sbp_abc',
      );
    });

    test('a scheme that is not bearer keeps its own spelling', () async {
      // Only one word is claimed here. A server using DPoP or something of its
      // own is entitled to be written the way it asked for.
      expect(
        entryWith('DPoP sbp_abc').headers['Authorization'],
        'DPoP sbp_abc',
      );
    });

    test('the token is never rewritten, only the scheme', () async {
      // The credential can contain anything, including the word bearer.
      expect(
        entryWith('bearer bearer-looking-token').headers['Authorization'],
        'Bearer bearer-looking-token',
      );
    });

    test('bearerToken strips the scheme however it is spelled', () async {
      // The same bug, one layer down: matching `Bearer ` literally returned the
      // *whole* header as the credential, and Hermes filed `bearer sbp_…` as
      // the token itself.
      expect(entryWith('bearer sbp_abc').bearerToken, 'sbp_abc');
      expect(entryWith('Bearer sbp_abc').bearerToken, 'sbp_abc');
      expect(entryWith('BEARER sbp_abc').bearerToken, 'sbp_abc');
    });

    test('a header with no scheme at all is the credential', () async {
      // Some providers use their own header name and put the bare key in it.
      final entry = McpEntry.fromJson({
        'url': 'https://mcp.example/x',
        'headers': {'X-Figma-Token': 'figd_abc'},
      })!;
      expect(entry.bearerToken, 'figd_abc');
    });
  });

  group('file protection', () {
    test('the store is written owner-only', () async {
      // The token is a live credential sitting in the user's home directory.
      // Skipped on Windows, where the ACL follows the profile and there is no
      // chmod to call.
      if (Platform.isWindows) return;
      await store.save(token('gmail'));

      final mode = await Process.run('stat', ['-f', '%Lp', store.file.path]);
      expect(mode.stdout.toString().trim(), '600');
    });
  });

  group('expiry', () {
    test('a token with no expiry is never treated as expired', () async {
      // "The provider did not say" is not the same as "already dead".
      expect(token('gmail').isExpired(), isFalse);
    });

    test(
      'expiry is judged with a head start, not on the exact second',
      () async {
        final now = DateTime(2026, 7, 30, 12);
        // Refreshing exactly at expiry loses a race with a request already in
        // flight, so a token expiring within the skew already counts as expired.
        expect(
          token(
            'gmail',
            expiresAt: now.add(const Duration(minutes: 2)),
          ).isExpired(now: now),
          isTrue,
        );
        expect(
          token(
            'gmail',
            expiresAt: now.add(const Duration(minutes: 30)),
          ).isExpired(now: now),
          isFalse,
        );
        expect(
          token(
            'gmail',
            expiresAt: now.subtract(const Duration(hours: 1)),
          ).isExpired(now: now),
          isTrue,
        );
      },
    );
  });

  group('which path obtained the token', () {
    test('a gateway token survives a round trip and stays gateway', () async {
      await store.save(token('gmail'));

      final read = (await store.read())['gmail']!;
      expect(read.source, ConnectorTokenSource.gateway);
      expect(read.issuer, isEmpty);
    });

    test('a self-registered token keeps its source and issuer', () async {
      await store.save(
        ConnectorToken(
          connector: 'notion',
          accessToken: 'access-notion',
          refreshToken: 'refresh-notion',
          source: ConnectorTokenSource.dcr,
          issuer: 'https://mcp.notion.com',
          mcpEntry: const McpEntry(
            url: 'https://mcp.notion.com/mcp',
            headers: {'Authorization': 'Bearer access-notion'},
            canRefresh: true,
          ),
        ),
      );

      final read = (await store.read())['notion']!;
      expect(read.source, ConnectorTokenSource.dcr);
      // The key into clients.json. Losing it makes the token unrenewable, since
      // the refresh call needs the client_id that was registered.
      expect(read.issuer, 'https://mcp.notion.com');
    });

    test(
      'a token written before path A existed reads as gateway, not dcr',
      () async {
        // The compatibility case, and the one worth pinning: every token already
        // on disk predates `source`. Defaulting a missing field to `dcr` would
        // send the refresh sweep hunting for a registration that never existed,
        // and the connector would silently stop renewing.
        await store.file.parent.create(recursive: true);
        await store.file.writeAsString(
          jsonEncode({
            'gmail': {
              'access_token': 'legacy',
              'token_type': 'Bearer',
              'refresh_token': 'legacy-refresh',
            },
          }),
        );

        final read = (await store.read())['gmail']!;
        expect(read.source, ConnectorTokenSource.gateway);
        expect(read.issuer, isEmpty);
      },
    );

    test('a gateway token writes no source field at all', () async {
      // Keeps existing files byte-identical: the default path adds nothing, so
      // saving an untouched store doesn't rewrite every entry.
      await store.save(token('gmail'));

      final raw =
          jsonDecode(await store.file.readAsString()) as Map<String, dynamic>;
      expect(raw['gmail'], isNot(contains('source')));
      expect(raw['gmail'], isNot(contains('issuer')));
    });

    test('both paths answer canBeRefreshed the same way', () async {
      // The refresh scheduler must not branch on source — only the controller
      // does, when it picks which endpoint to call.
      final gateway = token('gmail');
      final dcr = ConnectorToken(
        connector: 'notion',
        accessToken: 'a',
        source: ConnectorTokenSource.dcr,
        issuer: 'https://mcp.notion.com',
        mcpEntry: const McpEntry(url: 'https://x/mcp', canRefresh: true),
      );

      expect(gateway.canBeRefreshed, isTrue);
      expect(dcr.canBeRefreshed, isTrue);
    });
  });
}
