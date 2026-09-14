import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/pairing/e2ee_keys.dart';
import 'package:grid_app/infrastructure/pairing/relay_host_proof.dart';

import 'e2ee_test_bytes.dart';

/// What this file can and cannot prove, stated plainly.
///
/// It covers the half of the host proof that lives entirely on this side: the
/// id derivation, and every way a challenge can be refused before any key is
/// touched. It does **not** prove that this desktop can answer a challenge the
/// real relay sealed — nothing in this repo can, because the relay is a
/// separate program in a separate repository.
///
/// That agreement is proven by `tool/pairing_relay_probe.dart`, run by hand
/// against a live `python -m pairing_relay`, which is the same standing the
/// panel firmware has: a second implementation you drive, not a test you run.
void main() {
  group('the id a key owns', () {
    test('a known key derives the id the relay derives for it, which is the '
        'one cross-implementation fact this file can pin', () {
      // `pairing_relay.host_proof.derive_relay_host_id(bytes(32))` in the CLI
      // repo prints exactly this. Two languages, one SHA-256, one truncation.
      expect(deriveRelayHostId(repeatedBytes(0)), 'Zmh6rfhivXdsj8GL');
    });

    test('an id is 16 base64url characters and differs per key, so there is '
        'nothing to squat', () async {
      final first = await E2eeKeyPair.generate();
      final second = await E2eeKeyPair.generate();
      final id = deriveRelayHostId(first.publicKey);

      expect(id, hasLength(kRelayHostIdChars));
      expect(id, matches(RegExp(r'^[A-Za-z0-9_-]{16}$')));
      expect(deriveRelayHostId(second.publicKey), isNot(id));
    });

    test('a key of the wrong length is refused rather than truncated', () {
      expect(
        () => deriveRelayHostId(repeatedBytes(0, 31)),
        throwsArgumentError,
      );
    });
  });

  group('reading a challenge off the wire', () {
    Map<String, Object?> challenge() => {
      'type': 'host-challenge',
      'challengeId': 'abc',
      'relayEphemeralPublicKeyB64': base64.encode(repeatedBytes(1)),
      'nonceB64': base64.encode(repeatedBytes(2, kRelayChallengeNonceLength)),
      'ciphertextB64': base64.encode(repeatedBytes(3, 80)),
      'expiresAt': 1757000000000,
    };

    test('a well-formed challenge is read back field for field', () {
      final parsed = RelayHostChallenge.fromJson(challenge());
      expect(parsed, isNotNull);
      expect(parsed!.challengeId, 'abc');
      expect(parsed.nonce, hasLength(kRelayChallengeNonceLength));
      expect(parsed.expiresAtMs, 1757000000000);
    });

    test('a nonce or key of the wrong length is refused, because the AEAD '
        'would otherwise fail somewhere less obvious', () {
      expect(
        RelayHostChallenge.fromJson({
          ...challenge(),
          'nonceB64': base64.encode(repeatedBytes(2, 24)),
        }),
        isNull,
      );
      expect(
        RelayHostChallenge.fromJson({
          ...challenge(),
          'relayEphemeralPublicKeyB64': base64.encode(repeatedBytes(1, 31)),
        }),
        isNull,
      );
    });

    test('anything that is not a host-challenge is refused', () {
      expect(
        RelayHostChallenge.fromJson({...challenge(), 'type': 'ping'}),
        isNull,
      );
      expect(RelayHostChallenge.fromJson(null), isNull);
      expect(RelayHostChallenge.fromJson('host-challenge'), isNull);
      final missing = {...challenge()}..remove('challengeId');
      expect(RelayHostChallenge.fromJson(missing), isNull);
    });
  });

  group('refusing to answer', () {
    test('a challenge sealed to somebody else is refused as unreadable, and '
        'that is the only thing the reason is allowed to say', () async {
      final keys = await E2eeKeyPair.generate();
      final outcome = await answerRelayHostChallenge(
        RelayHostChallenge(
          challengeId: 'abc',
          relayEphemeralPublicKey: (await E2eeKeyPair.generate()).publicKey,
          nonce: repeatedBytes(2, kRelayChallengeNonceLength),
          // Not a real seal; nothing can open it.
          ciphertext: repeatedBytes(9, 80),
          expiresAtMs: DateTime.now().millisecondsSinceEpoch + 10000,
        ),
        hostKeyPair: keys,
        context: RelayHostProofContext(
          relayOrigin: 'ws://relay.test:8787',
          relayHostId: deriveRelayHostId(keys.publicKey),
          hostPublicKey: keys.publicKey,
        ),
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );

      final refused = outcome as RelayHostProofRefused;
      expect(refused.check, 'challenge-undecryptable');
    });

    test('a ciphertext too short to hold a transcript is refused before any '
        'key work happens', () async {
      final keys = await E2eeKeyPair.generate();
      final outcome = await answerRelayHostChallenge(
        RelayHostChallenge(
          challengeId: 'abc',
          relayEphemeralPublicKey: keys.publicKey,
          nonce: repeatedBytes(2, kRelayChallengeNonceLength),
          ciphertext: Uint8List(8),
          expiresAtMs: DateTime.now().millisecondsSinceEpoch + 10000,
        ),
        hostKeyPair: keys,
        context: RelayHostProofContext(
          relayOrigin: 'ws://relay.test:8787',
          relayHostId: deriveRelayHostId(keys.publicKey),
          hostPublicKey: keys.publicKey,
        ),
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );

      expect((outcome as RelayHostProofRefused).check, 'ciphertext-too-short');
    });
  });
}
