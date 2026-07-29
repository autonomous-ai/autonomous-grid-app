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
}
