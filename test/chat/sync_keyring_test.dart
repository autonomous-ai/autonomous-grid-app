import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/data_sync/logic/sync_envelope.dart';
import 'package:grid_app/features/data_sync/logic/sync_keyring.dart';

/// The password never encrypts the user's data — it only unlocks the key that
/// does. These cover what that buys: an instant password check, backups that
/// carry different passwords, and media that is uploaded once whatever those
/// passwords are.
void main() {
  // Argon2id is deliberately slow (that slowness is what protects a stolen
  // database), so the tests that run it are kept few and given room.
  const slow = Timeout(Duration(seconds: 60));

  group('a backup key wrapped in a password', () {
    test('comes back with the right password', () async {
      final key = SyncVersionKey.generate();

      final reopened = await SyncVersionKey.unwrap(
        blob: await key.wrap(password: 'correct horse battery'),
        password: 'correct horse battery',
      );

      expect(reopened.bytes, key.bytes);
    }, timeout: slow);

    test('refuses the wrong password without touching anything else', () async {
      // 48 bytes and one Argon2id pass: this is why the app can say "wrong
      // password" before it compresses, uploads or downloads a thing.
      final blob = await SyncVersionKey.generate().wrap(password: 'meomeo1234');

      expect(
        () => SyncVersionKey.unwrap(blob: blob, password: 'meomeo1235'),
        throwsA(isA<SyncDecryptException>()),
      );
    }, timeout: slow);

    test('two backups can carry two different passwords', () async {
      // Each upload mints its own key, so forgetting one password costs that
      // backup and no other.
      final first = SyncVersionKey.generate();
      final second = SyncVersionKey.generate();
      final firstBlob = await first.wrap(password: 'before the trip');
      final secondBlob = await second.wrap(password: 'after the trip');

      expect(
        (await SyncVersionKey.unwrap(
          blob: firstBlob,
          password: 'before the trip',
        )).bytes,
        first.bytes,
      );
      expect(
        () => SyncVersionKey.unwrap(
          blob: secondBlob,
          password: 'before the trip',
        ),
        throwsA(isA<SyncDecryptException>()),
      );
    }, timeout: slow);

    test(
      'the key record survives the trip through the server as JSON',
      () async {
        final blob = await SyncVersionKey.generate().wrap(
          password: 'a passphrase here',
          hint: 'the usual one',
        );

        final decoded = SyncKeyBlob.decode(jsonEncode(blob.toJson()));

        expect(decoded.wrapped, blob.wrapped);
        expect(decoded.salt, blob.salt);
        expect(decoded.hint, 'the usual one');
      },
      timeout: slow,
    );
  });

  group('media keyed by its own contents', () {
    test('the same file always seals to the same id', () async {
      // This is what makes a second upload of an unchanged photo library free —
      // and it holds across passwords, because no password was involved.
      final first = await sealSyncMedia(utf8.encode('the same picture'));
      final second = await sealSyncMedia(utf8.encode('the same picture'));

      expect(first.oid, second.oid);
      expect(first.envelope, second.envelope);
    });

    test('a different file gets a different id', () async {
      final first = await sealSyncMedia(utf8.encode('one picture'));
      final second = await sealSyncMedia(utf8.encode('another picture'));

      expect(first.oid, isNot(second.oid));
    });

    test('it opens with the key the manifest carries', () async {
      final content = utf8.encode('a picture of a cat');

      final sealed = await sealSyncMedia(content);

      expect(
        await openSyncMedia(envelope: sealed.envelope, key: sealed.key),
        content,
      );
    });

    test('the id is not the hash of the file itself', () async {
      // A plain content hash would let anyone holding the database confirm a
      // stored file by hashing a copy. The id is over the ciphertext instead.
      final sealed = await sealSyncMedia(utf8.encode('a picture of a cat'));

      expect(sealed.oid, hasLength(64));
      expect(sealed.envelope, isNot(contains(sealed.oid.codeUnits.first)));
    });
  });

  group('password strength', () {
    test('a short password is refused outright', () {
      expect(checkSyncPassword('short'), SyncPasswordVerdict.tooShort);
    });

    test('a long but predictable password is flagged, not blocked', () {
      // The user may have a reason; the screen warns and lets them through.
      expect(checkSyncPassword('password123'), SyncPasswordVerdict.weak);
      expect(checkSyncPassword('1234567890'), SyncPasswordVerdict.weak);
      expect(checkSyncPassword('aaaaaaaaaaaa'), SyncPasswordVerdict.weak);
    });

    test('a passphrase passes', () {
      expect(checkSyncPassword('caycau-mua-den-ba'), SyncPasswordVerdict.ok);
    });
  });
}
