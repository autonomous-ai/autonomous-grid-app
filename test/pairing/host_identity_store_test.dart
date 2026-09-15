import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/pairing_host/host_identity_store.dart';
import 'package:grid_pairing/grid_pairing.dart';

/// This computer's identity on the phone link. Every phone that has ever paired
/// pinned the public half, so this file is the one whose loss un-pairs the lot.
void main() {
  late Directory home;

  setUp(() => home = Directory.systemTemp.createTempSync('grid-identity-'));
  tearDown(() => home.deleteSync(recursive: true));

  File identityFile() => File('${home.path}/pairing_identity.json');

  test(
    'a first run creates a keypair and keeps it owner-readable only',
    () async {
      final store = HostIdentityStore(file: identityFile());
      final created = await store.loadOrCreate();

      expect(created.publicKey, hasLength(kE2eeKeyLength));
      expect(identityFile().existsSync(), isTrue);
      if (!Platform.isWindows) {
        // A private key at 0644 in a shared home is the whole link's security,
        // readable by anything else running as another user on the machine.
        final mode = identityFile().statSync().modeString();
        expect(mode.substring(3), '------', reason: 'mode was $mode');
      }
    },
  );

  test('a second run returns the same identity, because replacing it would '
      'un-pair every phone that ever scanned a code', () async {
    final store = HostIdentityStore(file: identityFile());
    final first = await store.loadOrCreate();
    final second = await store.loadOrCreate();

    expect(second.publicKey, first.publicKey);
    expect(second.privateKey, first.privateKey);
  });

  test('a file that exists but cannot be read stops the app rather than being '
      'replaced — the failure says nothing about the contents', () async {
    // The dangerous case: a directory where a file is expected reproduces
    // "the read failed" without needing to break permissions, which does not
    // work when the tests run as root.
    Directory(identityFile().path).createSync();
    final store = HostIdentityStore(file: identityFile());

    await expectLater(
      store.loadOrCreate(),
      throwsA(isA<HostIdentityUnreadable>()),
    );
  });

  test('a corrupt file is replaced, because unreadable JSON really does mean '
      'there is no identity to lose', () async {
    identityFile().writeAsStringSync('{ this is not json');
    final store = HostIdentityStore(file: identityFile());

    final created = await store.loadOrCreate();
    expect(created.publicKey, hasLength(kE2eeKeyLength));
  });

  test(
    'a file from a future version is replaced rather than half-read',
    () async {
      identityFile().writeAsStringSync(
        jsonEncode({'v': 99, 'privateKeyB64': 'x'}),
      );
      final store = HostIdentityStore(file: identityFile());

      expect((await store.loadOrCreate()).publicKey, hasLength(kE2eeKeyLength));
    },
  );

  test('the stored public key and relay host id agree with the private key, '
      'so nothing downstream has to re-derive them to be safe', () async {
    final store = HostIdentityStore(file: identityFile());
    final created = await store.loadOrCreate();

    final stored =
        jsonDecode(identityFile().readAsStringSync()) as Map<String, Object?>;
    expect(stored['publicKeyB64'], base64.encode(created.publicKey));
    expect(stored['relayHostId'], deriveRelayHostId(created.publicKey));
  });
}
