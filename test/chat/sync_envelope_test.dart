import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/data_sync/logic/sync_envelope.dart';

/// The envelope is what makes a backup self-describing without being readable.
/// These cover the two failures a user can actually hit — a damaged download and
/// a wrong password — which must never be reported as each other.
void main() {
  final key = SecretKey(List<int>.generate(32, (i) => i));
  final otherKey = SecretKey(List<int>.generate(32, (i) => 255 - i));

  Future<List<int>> seal(List<int> plaintext, {SecretKey? with_}) =>
      sealSyncEnvelope(
        plaintext: plaintext,
        key: with_ ?? key,
        header: SyncEnvelopeHeader(
          kind: syncEnvelopeKindSnapshot,
          createdAt: DateTime.utc(2026, 8, 11),
          device: 'MacBook-Tony',
          app: '0.2.0',
          counts: const {'chats': 42},
          objectIds: const ['ab12'],
        ),
      );

  test('a sealed payload comes back byte for byte', () async {
    final plaintext = utf8.encode('a chat, or a picture, or anything');

    final opened = await openSyncEnvelope(
      envelope: await seal(plaintext),
      key: key,
    );

    expect(opened, plaintext);
  });

  test('the wrong key is a decrypt failure, not a format failure', () async {
    // This is how the app tells the user "wrong password" instead of "this file
    // is damaged" — two different problems with two different fixes.
    final envelope = await seal(utf8.encode('secret'));

    expect(
      () => openSyncEnvelope(envelope: envelope, key: otherKey),
      throwsA(isA<SyncDecryptException>()),
    );
  });

  test('bytes that are not a Grid payload fail as a format problem', () async {
    expect(
      () => openSyncEnvelope(envelope: utf8.encode('hello'), key: key),
      throwsA(isA<SyncFormatException>()),
    );
  });

  test(
    'a truncated download fails rather than decrypting to nonsense',
    () async {
      final envelope = await seal(utf8.encode('a chat'));

      expect(
        () => openSyncEnvelope(
          envelope: envelope.sublist(0, envelope.length - 8),
          key: key,
        ),
        throwsA(anyOf(isA<SyncFormatException>(), isA<SyncDecryptException>())),
      );
    },
  );

  test('the header can be read without the key at all', () async {
    // The backup list has to say "42 chats, from MacBook-Tony" before the user
    // decides which one to type a password for.
    final header = readSyncEnvelopeHeader(await seal(utf8.encode('x')));

    expect(header.device, 'MacBook-Tony');
    expect(header.counts['chats'], 42);
    expect(header.objectIds, ['ab12']);
  });

  test('a tampered header breaks decryption', () async {
    // The header is the AES-GCM aad, which is what stops the server rewriting
    // the object list or the device name on a backup it cannot read.
    final envelope = [...await seal(utf8.encode('x'))];
    final at = envelope.indexOf(utf8.encode('MacBook-Tony').first);
    envelope[at] = envelope[at] ^ 0x01;

    expect(
      () => openSyncEnvelope(envelope: envelope, key: key),
      throwsA(isA<SyncDecryptException>()),
    );
  });
}
