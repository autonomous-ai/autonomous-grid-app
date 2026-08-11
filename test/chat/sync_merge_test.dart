import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/data_sync/logic/sync_bundle.dart';
import 'package:grid_app/features/data_sync/logic/sync_merge.dart';

/// Restoring a backup must never cost the user work they haven't backed up.
/// These cover the ways that promise can break: a chat only this machine has,
/// two machines editing the same chat, stamps that can't be compared, what the
/// dialog promises before any of it happens, and fields a newer build added.
void main() {
  Map<String, Object?> chat(
    String id, {
    String? updatedAt,
    int messages = 1,
    Map<String, Object?> extra = const {},
  }) => {
    'id': id,
    'title': id,
    'updatedAt': updatedAt ?? '2026-08-01T10:00:00.000Z',
    'messages': [
      for (var i = 0; i < messages; i++) {'role': 'user', 'text': 'm$i'},
    ],
    ...extra,
  };

  group('mergeChatFiles', () {
    test('a chat only this computer has is left alone', () {
      final result = mergeChatFiles(
        local: {'local-only': chat('local-only')},
        cloud: {'from-cloud': chat('from-cloud')},
      );

      expect(result.write.keys, ['from-cloud']);
      expect(result.actions['local-only'], isNull);
    });

    test('the newer copy of a chat edited on both computers wins', () {
      final result = mergeChatFiles(
        local: {'a': chat('a', updatedAt: '2026-08-01T10:00:00.000Z')},
        cloud: {
          'a': chat('a', updatedAt: '2026-08-02T10:00:00.000Z', messages: 5),
        },
      );

      expect(result.actions['a'], ChatMergeAction.replacedByCloud);
      expect((result.write['a']!['messages'] as List), hasLength(5));
    });

    test('an older copy in the backup never overwrites newer work here', () {
      final result = mergeChatFiles(
        local: {'a': chat('a', updatedAt: '2026-08-05T10:00:00.000Z')},
        cloud: {'a': chat('a', updatedAt: '2026-08-02T10:00:00.000Z')},
      );

      expect(result.actions['a'], ChatMergeAction.keptLocal);
      expect(result.write, isEmpty);
    });

    test('when the stamps tie, the copy with more messages wins', () {
      // Two machines can write the same second, and chats saved before stamps
      // carried a zone read as the epoch on both sides. "Newest" can't decide
      // either case; the longer transcript is the one that loses nothing.
      final result = mergeChatFiles(
        local: {'a': chat('a', updatedAt: 'not a date', messages: 2)},
        cloud: {'a': chat('a', updatedAt: 'not a date', messages: 9)},
      );

      expect(result.actions['a'], ChatMergeAction.replacedByCloud);
    });

    test('the comparison reads the stamp in the file, not the file itself', () {
      // A copy, an unzip or the restore itself resets a file's modification
      // time to now — every restored chat would look like the newest thing on
      // the disk. `updatedAt` is written by the app when a message lands.
      final older = chat('a', updatedAt: '2026-08-01T10:00:00.000Z');
      final newer = chat('a', updatedAt: '2026-08-02T10:00:00.000Z');

      expect(cloudCopyWins(mine: older, theirs: newer), isTrue);
      expect(cloudCopyWins(mine: newer, theirs: older), isFalse);
    });

    test('a zoneless stamp is read as local time, not as UTC', () {
      // Files written before the UTC change carry no `Z`. Reading one as UTC
      // would shift it by the machine's offset and flip a comparison — which is
      // exactly how a merge would delete an afternoon of work.
      final local = DateTime(2026, 8, 3, 12);
      final parsed = parseSyncTimestamp('2026-08-03T12:00:00.000000');

      expect(parsed, local);
    });

    test('fields this build does not know survive the merge', () {
      // The other machine may run a newer app. Decoding into this build's model
      // and re-encoding would silently drop whatever it added.
      final result = mergeChatFiles(
        local: const {},
        cloud: {
          'a': chat('a', extra: {'someFutureField': 42}),
        },
      );

      expect(result.write['a']!['someFutureField'], 42);
    });
  });

  group('previewRestore', () {
    test('names the chats a restore would write over, before it writes', () {
      // The one lossy thing a restore does, so the dialog has to name them —
      // a count alone doesn't let anyone judge whether it's fine.
      final preview = previewRestore(
        local: {
          'a': {
            'id': 'a',
            'title': 'Tax questions',
            'updatedAt': '2026-08-01T10:00:00.000Z',
          },
          'keep': {'id': 'keep', 'title': 'Only here'},
        },
        cloud: {
          'a': chat('a', updatedAt: '2026-08-09T10:00:00.000Z'),
          'b': chat('b'),
        },
      );

      expect(preview.replaced, 1);
      expect(preview.replacedTitles, ['Tax questions']);
      expect(preview.added, 1);
    });

    test('a chat this computer has worked on more recently is not listed', () {
      // The preview has to predict the merge exactly, or the dialog promises
      // something else than what happens.
      final preview = previewRestore(
        local: {
          'a': {
            'id': 'a',
            'title': 'Still mine',
            'updatedAt': '2026-08-09T10:00:00.000Z',
          },
        },
        cloud: {'a': chat('a', updatedAt: '2026-08-01T10:00:00.000Z')},
      );

      expect(preview.replaced, 0);
      expect(preview.keptLocal, 1);
    });

    test('a chat with no title still gets a name in the dialog', () {
      final preview = previewRestore(
        local: {
          'a': {
            'id': 'a',
            'title': '',
            'updatedAt': '2026-07-01T10:00:00.000Z',
          },
        },
        cloud: {'a': chat('a')},
      );

      expect(preview.replacedTitles, ['Untitled chat']);
    });

    test('nothing in common means nothing to ask about', () {
      // A first restore on a new computer must not stop for a dialog.
      final preview = previewRestore(local: const {}, cloud: {'a': chat('a')});

      expect(preview.replaced, 0);
      expect(preview.added, 1);
    });
  });

  group('rewriteMediaPaths', () {
    test("an image's path is repointed at where the file landed here", () {
      final rewritten = rewriteMediaPaths(
        {
          'id': 'a',
          'messages': [
            {
              'role': 'assistant',
              'text': 'here',
              'media': [
                {'path': '/Users/other/.grid/outputs/pic.png', 'kind': 'image'},
              ],
            },
          ],
        },
        {
          '/Users/other/.grid/outputs/pic.png':
              '/Users/me/.grid/outputs/synced/ab.png',
        },
      );

      final media =
          (rewritten['messages'] as List).first as Map<String, Object?>;
      expect(
        ((media['media'] as List).first as Map)['path'],
        '/Users/me/.grid/outputs/synced/ab.png',
      );
      // The kind rides along untouched — rewriting a path must not rebuild the
      // record around it.
      expect(((media['media'] as List).first as Map)['kind'], 'image');
    });

    test('a file that did not travel keeps its original path', () {
      // Dropping it would hide the gap; leaving it shows a file the chat can't
      // find, which is the truth, and the manifest says why.
      final original = {
        'id': 'a',
        'messages': [
          {
            'role': 'user',
            'files': [
              {'path': '/Users/other/Desktop/notes.txt', 'name': 'notes.txt'},
            ],
          },
        ],
      };

      final rewritten = rewriteMediaPaths(original, {'/elsewhere': '/here'});

      final message =
          (rewritten['messages'] as List).first as Map<String, Object?>;
      expect(
        ((message['files'] as List).first as Map)['path'],
        '/Users/other/Desktop/notes.txt',
      );
    });

    test('media rewrites are keyed by the path the other machine wrote', () {
      final manifest = SyncManifest(
        createdAt: DateTime.utc(2026, 8, 1),
        device: 'Mac',
        app: '1.0.0',
        chatCount: 1,
        promptCount: 0,
        projectCount: 0,
        media: const [
          SyncMediaEntry(
            oid: 'ab12',
            key: [1, 2, 3],
            source: '/Users/other/.grid/outputs/pic.png',
            rel: 'outputs/pic.png',
            bytes: 10,
          ),
        ],
      );

      final rewrites = buildMediaRewrites(
        manifest: manifest,
        localPathFor: (entry) => '/here/${entry.oid}.png',
      );

      expect(rewrites, {
        '/Users/other/.grid/outputs/pic.png': '/here/ab12.png',
      });
    });
  });

  group('mergeRecordsById', () {
    test('records only the backup has are appended, keeping their order', () {
      final merged = mergeRecordsById(
        local: [
          {'id': '1', 'name': 'mine'},
        ],
        cloud: [
          {'id': '2', 'name': 'theirs'},
          {'id': '3', 'name': 'also theirs'},
        ],
      );

      expect([for (final r in merged) r['id']], ['1', '2', '3']);
    });

    test("a project this computer already has keeps its own folder path", () {
      // The other machine's `path` points at a folder that isn't on this disk.
      final merged = mergeRecordsById(
        local: [
          {'id': '1', 'name': 'bubu', 'path': '/Users/me/work'},
        ],
        cloud: [
          {'id': '1', 'name': 'bubu', 'path': '/Users/other/work'},
        ],
      );

      expect(merged.single['path'], '/Users/me/work');
    });

    test('a prompt edited more recently elsewhere replaces the local copy', () {
      final merged = mergeRecordsById(
        local: [
          {'id': '1', 'text': 'old', 'updatedAt': '2026-08-01T00:00:00.000Z'},
        ],
        cloud: [
          {'id': '1', 'text': 'new', 'updatedAt': '2026-08-09T00:00:00.000Z'},
        ],
        preferNewer: true,
      );

      expect(merged.single['text'], 'new');
    });
  });
}
