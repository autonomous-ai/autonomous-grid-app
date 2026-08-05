import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/adapters/hermes_token_projection.dart';
import 'package:grid_app/features/agents/logic/connector_token.dart';

void main() {
  late Directory home;
  late HermesTokenProjection projection;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('hermes_token_projection');
    projection = HermesTokenProjection(home: home.path);
  });
  tearDown(() => home.delete(recursive: true));

  ConnectorToken token(String connector, {DateTime? expiresAt}) {
    return ConnectorToken(
      connector: connector,
      accessToken: 'access-$connector',
      refreshToken: 'refresh-$connector',
      expiresAt: expiresAt,
      scope: 'read',
    );
  }

  Map<String, dynamic> readToken(String connector) {
    final raw = projection.tokenFile(connector).readAsStringSync();
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  group('the file Hermes will read', () {
    test('carries the RFC 6749 fields Hermes validates against', () async {
      await projection.project([token('gmail')]);

      final json = readToken('gmail');
      expect(json['access_token'], 'access-gmail');
      expect(json['token_type'], 'Bearer');
      expect(json['refresh_token'], 'refresh-gmail');
      expect(json['scope'], 'read');
    });

    test(
      'writes both expires_in and expires_at, so Hermes agrees with itself',
      () async {
        // Hermes stores an absolute `expires_at` and rewrites `expires_in` from
        // it on read. Writing only one leaves the other stale on whichever path
        // it happens to take.
        final expiry = DateTime.now().add(const Duration(hours: 1));
        await projection.project([token('gmail', expiresAt: expiry)]);

        final json = readToken('gmail');
        expect(json['expires_at'], expiry.millisecondsSinceEpoch ~/ 1000);
        expect(json['expires_in'], closeTo(3600, 5));
      },
    );

    test(
      'an already-expired token writes expires_in 0, never a negative',
      () async {
        await projection.project([
          token(
            'gmail',
            expiresAt: DateTime.now().subtract(const Duration(days: 1)),
          ),
        ]);
        expect(readToken('gmail')['expires_in'], 0);
      },
    );

    test(
      'a token with no expiry omits both fields rather than guessing',
      () async {
        await projection.project([token('gmail')]);
        final json = readToken('gmail');
        expect(json.containsKey('expires_at'), isFalse);
        expect(json.containsKey('expires_in'), isFalse);
      },
    );

    test('lands in mcp-tokens/ under the Hermes home', () async {
      await projection.project([token('gmail')]);
      expect(
        projection.tokenFile('gmail').path,
        '${home.path}/mcp-tokens/gmail.json',
      );
    });

    test('is written owner-only — it holds a live credential', () async {
      if (Platform.isWindows) return;
      await projection.project([token('gmail')]);
      final mode = await Process.run('stat', [
        '-f',
        '%Lp',
        projection.tokenFile('gmail').path,
      ]);
      expect(mode.stdout.toString().trim(), '600');
    });

    test('only the tokens file is ours to write', () async {
      // `.client.json` comes from config.yaml via Hermes's own
      // _maybe_preregister_client, and `.meta.json` it discovers. Writing
      // either would be guessing at state Hermes owns.
      await projection.project([token('gmail')]);
      final files = Directory(
        '${home.path}/mcp-tokens',
      ).listSync().map((e) => e.path.split('/').last).toList();
      expect(files, ['gmail.json']);
    });
  });

  group('projection removes only what it is told to remove', () {
    test('a connector named in removing has its file deleted', () async {
      await projection.project([token('gmail'), token('slack')]);
      expect(projection.tokenFile('slack').existsSync(), isTrue);

      // Disconnecting has to actually stop the agent using it — a file left
      // behind keeps working until it expires.
      await projection.project([token('gmail')], removing: {'slack'});
      expect(projection.tokenFile('gmail').existsSync(), isTrue);
      expect(projection.tokenFile('slack').existsSync(), isFalse);
    });

    test('a connector merely absent from the list is left alone', () async {
      // The regression this parameter exists for. `project` used to delete
      // every file it "owned" that was missing from the list, which makes an
      // empty list mean "delete everything" — and an empty list is what an
      // unreadable store, or one connector's failed refresh, produces. On
      // 2026-07-30 that erased two working connectors nobody had touched.
      await projection.project([token('gmail'), token('slack')]);

      await projection.project(const []);

      expect(projection.tokenFile('gmail').existsSync(), isTrue);
      expect(projection.tokenFile('slack').existsSync(), isTrue);
    });

    test('a server Hermes authorized on its own is never touched', () async {
      // Hermes has its own OAuth flow for DCR providers. Those tokens are not
      // ours to manage, and deleting one would silently break a working tool.
      final dir = Directory('${home.path}/mcp-tokens')
        ..createSync(recursive: true);
      File('${dir.path}/notion.json').writeAsStringSync('{"access_token":"x"}');

      await projection.project([token('gmail')], removing: {'gmail'});
      expect(File('${dir.path}/notion.json').existsSync(), isTrue);
    });

    test('projecting nothing at all does not create the directory', () async {
      await projection.project(const []);
      expect(Directory('${home.path}/mcp-tokens').existsSync(), isFalse);
    });
  });

  group('safeFileName mirrors Hermes _safe_filename', () {
    // re.sub(r"[^\w\-]", "_", name).strip("_")[:128] or "default"
    test('keeps word characters, dashes and underscores', () {
      expect(safeFileName('google_drive-v2'), 'google_drive-v2');
    });

    test('substitutes anything else', () {
      expect(safeFileName('my server/../etc'), 'my_server____etc');
      expect(safeFileName('a.b'), 'a_b');
    });

    test('keeps Unicode letters, because Python \\w does', () {
      // Dart's own \\w is ASCII-only: it would write café.json as caf_.json, a
      // file the agent then never opens — and nothing about that failure looks
      // like a bug. Verified against the real function, which returns both of
      // these unchanged.
      expect(safeFileName('café'), 'café');
      expect(safeFileName('日本語'), '日本語');
    });

    test('strips underscores from both ends after substituting', () {
      expect(safeFileName('/leading'), 'leading');
      expect(safeFileName('trailing/'), 'trailing');
      expect(safeFileName('__both__'), 'both');
    });

    test('clips at 128 characters', () {
      expect(safeFileName('a' * 200).length, 128);
    });

    test('a name with nothing usable becomes "default", not empty', () {
      expect(safeFileName('///'), 'default');
      expect(safeFileName(''), 'default');
    });
  });
}
