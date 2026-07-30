import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/connectors/logic/dcr_client_store.dart';

void main() {
  late Directory home;
  late DcrClientStore store;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('grid_dcr_clients');
    store = DcrClientStore(home: home);
  });
  tearDown(() => home.delete(recursive: true));

  DcrClient client({
    String issuer = 'https://api.supabase.com',
    String? secret = 'a-secret',
    String authMethod = 'client_secret_post',
    String redirectUri = 'http://127.0.0.1:61854/callback',
  }) => DcrClient(
    issuer: issuer,
    clientId: 'client-for-$issuer',
    clientSecret: secret,
    authMethod: authMethod,
    authorizationEndpoint: '$issuer/v1/oauth/authorize',
    tokenEndpoint: '$issuer/v1/oauth/token',
    redirectUri: redirectUri,
    registeredAt: DateTime.fromMillisecondsSinceEpoch(1785396105 * 1000),
  );

  group('round trip', () {
    test('a registration survives being written and read back', () async {
      await store.save(client());

      final read = (await store.read())['https://api.supabase.com']!;
      expect(read.clientId, 'client-for-https://api.supabase.com');
      // Supabase issues a secret even through dynamic registration, so a DCR
      // client is not always a public one — measured 2026-07-30.
      expect(read.clientSecret, 'a-secret');
      expect(read.authMethod, 'client_secret_post');
      expect(read.isPublic, isFalse);
    });

    test('a public client stores no secret and says so', () async {
      // Notion and Linear: no secret at all, `token_endpoint_auth_method: none`.
      await store.save(
        client(
          issuer: 'https://mcp.notion.com',
          secret: null,
          authMethod: 'none',
        ),
      );

      final read = (await store.read())['https://mcp.notion.com']!;
      expect(read.clientSecret, isNull);
      expect(read.isPublic, isTrue);
      expect(
        jsonDecode(await store.file.readAsString())['https://mcp.notion.com'],
        isNot(contains('client_secret')),
      );
    });

    test('two issuers keep separate registrations', () async {
      await store.save(client());
      await store.save(client(issuer: 'https://mcp.notion.com'));

      expect((await store.read()).keys, hasLength(2));
    });
  });

  group('reuse across connects', () {
    test('the redirect URI is kept, because reuse is decided on it', () async {
      // Reconnecting has to authorize on a URI the client is registered for.
      // RFC 8252 §7.3 asks servers to accept any loopback port; measured
      // 2026-07-30, Achriom does not — it answers `invalid_redirect_uri` for a
      // port it never saw, which is why the port is stable and why this value
      // has to survive a round trip exactly.
      await store.save(client(redirectUri: 'http://127.0.0.1:51789/callback'));

      final stored = (await store.read())['https://api.supabase.com']!;

      expect(stored.redirectUri, 'http://127.0.0.1:51789/callback');
    });

    test('an entry saved without one reads back empty, not null', () async {
      // A registration written before redirect URIs were recorded. It must not
      // match any live URI — re-registering is correct there, and a null here
      // would crash the comparison instead.
      await store.save(client(redirectUri: ''));

      expect((await store.read())['https://api.supabase.com']!.redirectUri, '');
    });
  });

  group('degrading rather than failing', () {
    test('a missing file is an empty store', () async {
      expect(await store.read(), isEmpty);
    });

    test('a file that will not parse reads as empty', () async {
      await store.directory.create(recursive: true);
      await store.file.writeAsString('{not json');

      // Worst case is one extra registration, which beats blocking the screen
      // that could fix it.
      expect(await store.read(), isEmpty);
    });

    test('one unusable row drops itself, the rest survive', () async {
      await store.directory.create(recursive: true);
      await store.file.writeAsString(
        jsonEncode({
          'https://broken.example': {'client_id': ''},
          'https://good.example': {
            'client_id': 'ok',
            'authorization_endpoint': 'https://good.example/authorize',
            'token_endpoint': 'https://good.example/token',
          },
        }),
      );

      expect((await store.read()).keys, ['https://good.example']);
    });
  });

  test('the file is owner-only — it can hold a client secret', () async {
    if (Platform.isWindows) return;
    await store.save(client());

    final mode = await Process.run('stat', ['-f', '%Lp', store.file.path]);
    expect(mode.stdout.toString().trim(), '600');
  });

  test('removing a registration leaves the others', () async {
    await store.save(client());
    await store.save(client(issuer: 'https://mcp.notion.com'));

    await store.remove('https://api.supabase.com');

    expect((await store.read()).keys, ['https://mcp.notion.com']);
  });
}
