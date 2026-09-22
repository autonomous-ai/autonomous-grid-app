import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_pairing/grid_pairing.dart';

import 'locator_fakes.dart';

/// The code a person carries between two devices, and the one record it
/// unlocks.
///
/// This is the whole of how a phone finds a computer, so it is tested as a
/// format rather than as a feature: the desktop seals a record and the phone
/// opens it, and the two never meet except through these bytes. Every case here
/// is one where a wrong answer looks exactly like "your computer is asleep" on
/// the phone — which is the hardest kind of failure to debug by hand, and the
/// reason this file exists at all (§8).
void main() {
  group('the code', () {
    test('is twenty characters of an alphabet with no lookalikes in it, which '
        'is what makes it safe to read down a phone line', () {
      final token = PairToken.generate();

      expect(token.normalized, hasLength(kPairTokenLength));
      for (final ch in token.normalized.split('')) {
        expect(kPairTokenAlphabet, contains(ch));
      }
      expect('IOLU'.split('').any(kPairTokenAlphabet.contains), isFalse);
    });

    test('is shown in groups of four, because twenty characters read off one '
        'screen and typed into another need somewhere to keep count', () {
      final token = PairToken.generate();

      expect(token.pretty, matches(RegExp(r'^([0-9A-Z]{4}-){4}[0-9A-Z]{4}$')));
      expect(PairToken.tryParse(token.pretty), token);
    });

    test('reads what a person types rather than what the format says: dashes, '
        'spaces, lower case, and the two characters nobody can see', () {
      final typed = PairToken.tryParse(' abcd-efgh 1234 5678-9jkm ');
      final lookalikes = PairToken.tryParse('OOOO-IIII-LLLL-0000-1111');

      expect(typed?.normalized, 'ABCDEFGH123456789JKM');
      // O is a zero and I and L are ones, so all twenty of these are digits.
      expect(lookalikes?.normalized, '00001111111100001111');
    });

    test('refuses anything that is not a code instead of repairing it — a code '
        'that is quietly wrong fails two layers away as "not recognised"', () {
      expect(PairToken.tryParse('ABCD-EFGH'), isNull);
      expect(PairToken.tryParse('ABCDEFGH123456789JKM1'), isNull);
      // U is not in the alphabet, and neither is punctuation.
      expect(PairToken.tryParse('UBCDEFGH123456789JKM'), isNull);
      expect(PairToken.tryParse('ABCD.EFGH123456789JKM'), isNull);
      expect(PairToken.tryParse('x' * 200), isNull);
    });

    test(
      'names a document of exactly the length the rules admit, and the same '
      'one on both devices every time — this is the appointment they keep',
      () {
        final token = PairToken.tryParse('ABCDEFGH123456789JKM')!;
        final same = PairToken.tryParse('abcd-efgh-1234-5678-9jkm')!;

        expect(token.locatorDocId, hasLength(32));
        expect(token.locatorDocId, matches(RegExp(r'^[0-9a-f]{32}$')));
        expect(same.locatorDocId, token.locatorDocId);
        expect(PairToken.generate().locatorDocId, isNot(token.locatorDocId));
      },
    );

    test(
      'derives the key under a different domain from the document name, so '
      'the id that travels in a URL says nothing about the key that does not',
      () {
        final token = PairToken.generate();

        expect(token.locatorKey, hasLength(32));
        // The id is a prefix of one hash and the key is the whole of another; the
        // hex of the key must not begin with the id.
        final keyHex = token.locatorKey
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        expect(keyHex.startsWith(token.locatorDocId), isFalse);
      },
    );

    test('never prints itself, because a code in a log line is somebody\'s '
        'computer in a log line', () {
      expect('${PairToken.generate()}', isNot(contains('-')));
      expect('${PairToken.generate()}', 'PairToken(…)');
    });

    test('is carried by a link as well as by hand, and only on the one route '
        'that is allowed to carry it', () {
      final token = PairToken.generate();

      expect(PairToken.tryParse(pairTokenTextOf(token.toLink())), token);
      expect(pairTokenTextOf('grid://open?token=${token.pretty}'), '');
      expect(pairTokenTextOf('grid://pair?code=${token.pretty}'), '');
      expect(pairTokenTextOf(token.pretty), token.pretty);
    });
  });

  group('the sealed record', () {
    final record = LocatorRecord(
      cellUrl: 'wss://phase-fridge-spa.trycloudflare.com',
      relayHostId: 'AbCdEfGh12345678',
      hostPublicKey: Uint8List.fromList(List.filled(32, 7)),
      hostName: "Huy's MacBook Pro",
      publishedAtMs: 1758500000000,
    );

    test('comes back exactly as it went in, because the phone dials what is in '
        'it and a single character off is a hostname that does not exist', () {
      final token = PairToken.generate();

      final opened = openLocatorRecord(
        sealLocatorRecord(record, token.locatorKey),
        token.locatorKey,
      );

      expect(opened, record);
      expect(opened?.cellUrl, record.cellUrl);
      expect(opened?.hostPublicKey, record.hostPublicKey);
      expect(opened?.hostName, record.hostName);
    });

    test('does not open with another code, which is the only thing standing '
        'between a public database and somebody\'s address', () {
      final blob = sealLocatorRecord(record, PairToken.generate().locatorKey);

      expect(openLocatorRecord(blob, PairToken.generate().locatorKey), isNull);
    });

    test('refuses a record that was altered rather than returning what is left '
        'of it — the address in it decides where the phone connects', () {
      final token = PairToken.generate();
      final blob = sealLocatorRecord(record, token.locatorKey);
      final raw = base64.decode(blob);
      raw[raw.length - 1] ^= 0xFF;

      expect(openLocatorRecord(base64.encode(raw), token.locatorKey), isNull);
      expect(openLocatorRecord('not base64 at all', token.locatorKey), isNull);
      expect(openLocatorRecord('', token.locatorKey), isNull);
    });

    test('is read as a version, so a record written by a newer Grid is a phone '
        'that says so rather than a phone that crashes', () {
      final fields = record.toJson()..['v'] = kLocatorRecordVersion + 1;

      expect(LocatorRecord.fromJson(fields), isNull);
    });

    test('refuses an address that is not a bare websocket origin, since the '
        'dialler appends a path to it', () {
      for (final bad in [
        'https://example.com',
        'wss://example.com/already/a/path',
        'wss://example.com?query=1',
        'wss://',
      ]) {
        expect(
          LocatorRecord.fromJson(record.toJson()..['cellUrl'] = bad),
          isNull,
          reason: bad,
        );
      }
    });

    test('compares by value, so republishing an address nobody changed is a '
        'write that does not happen', () {
      expect(LocatorRecord.fromJson(record.toJson()), record);
      expect(
        LocatorRecord.fromJson(record.toJson()..['hostName'] = 'Another Mac'),
        isNot(record),
      );
    });
  });

  group('the locator', () {
    final record = LocatorRecord(
      cellUrl: 'wss://quiet-lamp.trycloudflare.com',
      relayHostId: 'AbCdEfGh12345678',
      hostPublicKey: Uint8List.fromList(List.filled(32, 3)),
      hostName: 'This Mac',
      publishedAtMs: 1758500000000,
    );

    test('signs in once and publishes under the name the code derives, with '
        'nothing readable in the request but that name', () async {
      final fake = FakeLocatorTransport();
      final token = PairToken.generate();
      final client = LocatorClient(send: fake.send);

      expect(await client.publish(token, record), isNull);
      expect(await client.publish(token, record), isNull);

      // One sign-in for both writes: each one mints an anonymous user that never
      // goes away, and a computer republishes every time its tunnel moves.
      expect(
        fake.calls.where((c) => c.uri.path.contains('signUp')),
        hasLength(1),
      );
      final write = fake.calls[1];
      expect(write.method, 'PATCH');
      expect(
        write.uri.path,
        endsWith('/$kLocatorCollection/${token.locatorDocId}'),
      );
      expect(write.idToken, 'id-token-1');
      expect(write.body, isNot(contains(record.cellUrl)));
      expect(write.body, isNot(contains(token.normalized)));
    });

    test('reads a record back, which is the round trip the two apps actually '
        'make', () async {
      final token = PairToken.generate();
      final fake = FakeLocatorTransport()..give(token, record);
      final client = LocatorClient(send: fake.send);

      final (read, failure) = await client.read(token);

      expect(failure, isNull);
      expect(read, record);
    });

    test('answers "nothing published" rather than an error when there is no '
        'document, because that is what a computer that never started looks '
        'like', () async {
      final fake = FakeLocatorTransport();
      final client = LocatorClient(send: fake.send);

      final (read, failure) = await client.read(PairToken.generate());

      expect(read, isNull);
      expect(failure, isNull);
    });

    test('says the code does not match when a record is there and will not '
        'open, which is the one failure retrying cannot fix', () async {
      // A record that exists under this code's document, sealed with another.
      final token = PairToken.generate();
      final fake = FakeLocatorTransport();
      fake.documents[token.locatorDocId] = sealLocatorRecord(
        record,
        PairToken.generate().locatorKey,
      );
      final client = LocatorClient(send: fake.send);

      final (read, failure) = await client.read(token);

      expect(read, isNull);
      expect(failure, isA<LocatorUnreadable>());
    });

    test('signs in again when the session has expired, because an hour-old '
        'token on a computer left open for days is the normal case', () async {
      final token = PairToken.generate();
      final fake = FakeLocatorTransport()
        ..give(token, record)
        ..expireFirstCall = true;
      final client = LocatorClient(send: fake.send);

      final (read, failure) = await client.read(token);

      expect(failure, isNull);
      expect(read, record);
      expect(
        fake.calls.where((c) => c.uri.path.contains('signUp')),
        hasLength(2),
      );
      expect(fake.calls.last.idToken, 'id-token-2');
    });

    test('names the rules when the project refuses, because that is a thing to '
        'fix in Grid and not something a person can act on', () async {
      final fake = FakeLocatorTransport()..status = 403;
      final client = LocatorClient(send: fake.send);

      final failure = await client.publish(PairToken.generate(), record);

      expect(failure, isA<LocatorRefused>());
      expect(failure!.message, contains('rules'));
    });

    test('reports being offline as being offline, rather than as a code the '
        'screen would have to translate', () async {
      final fake = FakeLocatorTransport()..status = 0;
      final client = LocatorClient(send: fake.send);

      expect(
        await client.publish(PairToken.generate(), record),
        isA<LocatorOffline>(),
      );
    });

    test('erases the document when a phone is revoked, so it finds nothing '
        'instead of an address it can no longer use', () async {
      final fake = FakeLocatorTransport();
      final token = PairToken.generate();
      final client = LocatorClient(send: fake.send);

      expect(await client.erase(token), isNull);

      expect(fake.calls.last.method, 'DELETE');
      expect(
        fake.calls.last.uri.path,
        endsWith('/$kLocatorCollection/${token.locatorDocId}'),
      );
    });
  });
}
