import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/data_sync/logic/sync_bundle.dart';
import 'package:grid_app/features/data_sync/logic/sync_envelope.dart';

/// What travels with a backup and what doesn't — and, when something doesn't,
/// that the other machine is told why rather than showing a broken image.
void main() {
  const outputs = '/Users/me/.grid/outputs';

  group('referencedMediaPaths', () {
    test('finds both the pictures and the attached files a chat points at', () {
      final paths = referencedMediaPaths([
        {
          'id': 'a',
          'messages': [
            {
              'role': 'assistant',
              'media': [
                {'path': '$outputs/one.png', 'kind': 'image'},
              ],
            },
            {
              'role': 'user',
              'files': [
                {'path': '/Users/me/Desktop/report.pdf', 'name': 'report.pdf'},
              ],
            },
          ],
        },
      ]);

      expect(paths, ['$outputs/one.png', '/Users/me/Desktop/report.pdf']);
    });

    test('lists a file referenced by two chats once', () {
      final paths = referencedMediaPaths([
        {
          'id': 'a',
          'messages': [
            {
              'media': [
                {'path': '$outputs/one.png'},
              ],
            },
          ],
        },
        {
          'id': 'b',
          'messages': [
            {
              'media': [
                {'path': '$outputs/one.png'},
              ],
            },
          ],
        },
      ]);

      expect(paths, ['$outputs/one.png']);
    });
  });

  group('planSyncMedia', () {
    test("a file Grid made travels, and knows where it sat under ~/.grid", () {
      final plan = planSyncMedia(
        candidates: [(path: '$outputs/pic.png', bytes: 2048)],
        outputsPath: outputs,
      );

      expect(plan.picked.single.rel, 'outputs/pic.png');
      expect(plan.skipped, isEmpty);
    });

    test("a file from the user's own folders is left behind, and said so", () {
      // Grid syncs what Grid made. Someone's Desktop is not ours to copy to
      // another machine — but the chat still shows the file, so the reason has
      // to reach the other machine.
      final plan = planSyncMedia(
        candidates: [(path: '/Users/me/Desktop/taxes.pdf', bytes: 2048)],
        outputsPath: outputs,
      );

      expect(plan.picked, isEmpty);
      expect(plan.skipped.single.reason, SyncSkipReason.outsideOutputs);
    });

    test('a file over the cap is skipped with that as the reason', () {
      final plan = planSyncMedia(
        candidates: [
          (path: '$outputs/movie.mp4', bytes: syncMaxObjectBytes + 1),
        ],
        outputsPath: outputs,
      );

      expect(plan.skipped.single.reason, SyncSkipReason.tooLarge);
    });

    test('a file the chat points at but the disk lost is skipped', () {
      final plan = planSyncMedia(
        candidates: [(path: '$outputs/gone.png', bytes: null)],
        outputsPath: outputs,
      );

      expect(plan.skipped.single.reason, SyncSkipReason.missing);
    });

    test('a path that merely starts with the folder name is not inside it', () {
      // `~/.grid/outputs-old/` is a different folder; matching on the bare
      // prefix would sweep it in.
      final plan = planSyncMedia(
        candidates: [(path: '/Users/me/.grid/outputs-old/pic.png', bytes: 10)],
        outputsPath: outputs,
      );

      expect(plan.picked, isEmpty);
      expect(plan.skipped.single.reason, SyncSkipReason.outsideOutputs);
    });
  });

  group('the archive', () {
    test('entries come back with their names and bytes intact', () {
      final packed = packSyncArchive({
        'chats/1.json': utf8.encode('{"id":"1"}'),
        syncManifestEntry: utf8.encode('{"v":1}'),
      });

      final unpacked = unpackSyncArchive(packed);

      expect(utf8.decode(unpacked['chats/1.json']!), '{"id":"1"}');
      expect(unpacked.keys, contains(syncManifestEntry));
    });

    test('an entry name that could escape the folder is refused', () {
      // These bytes came off a server and are unpacked next to the user's real
      // chat history.
      final packed = packSyncArchive({
        '../../.ssh/authorized_keys': utf8.encode('nope'),
      });

      expect(
        () => unpackSyncArchive(packed),
        throwsA(isA<SyncFormatException>()),
      );
    });

    test(
      'a snapshot with no manifest is a format failure, not an empty restore',
      () {
        expect(
          () => readSyncManifest({'chats/1.json': utf8.encode('{}')}),
          throwsA(isA<SyncFormatException>()),
        );
      },
    );
  });

  group('the manifest', () {
    test('round-trips the media keys a restore needs', () {
      final manifest = SyncManifest(
        createdAt: DateTime.utc(2026, 8, 11, 9),
        device: 'MacBook-Tony',
        app: '0.2.0',
        chatCount: 42,
        promptCount: 3,
        projectCount: 2,
        media: const [
          SyncMediaEntry(
            oid: 'ab12',
            key: [1, 2, 3, 4],
            source: '$outputs/pic.png',
            rel: 'outputs/pic.png',
            bytes: 2048,
          ),
        ],
        skipped: const [
          SyncSkippedMedia(
            source: '/Users/me/Desktop/taxes.pdf',
            reason: SyncSkipReason.outsideOutputs,
          ),
        ],
      );

      final decoded = SyncManifest.fromJson(
        jsonDecode(jsonEncode(manifest.toJson())) as Map<String, Object?>,
      );

      expect(decoded.media.single.key, [1, 2, 3, 4]);
      expect(decoded.media.single.source, '$outputs/pic.png');
      expect(decoded.skipped.single.reason, SyncSkipReason.outsideOutputs);
      expect(decoded.chatCount, 42);
      expect(decoded.objectIds, ['ab12']);
    });
  });
}
