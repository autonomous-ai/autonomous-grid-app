/// The X25519 keys the phone link is built on, and the one exchange that turns
/// a pair of them into a shared secret.
///
/// Two keys with very different lifetimes meet here. The **desktop's** key is
/// long-lived: its public half goes into the sealed record every phone reads to
/// find this computer, so each of them has pinned it, and regenerating it
/// un-pairs all of them at once. The **phone's** key is ephemeral, fresh for each socket, which is what
/// gives the link forward secrecy — a desktop key recovered later opens nothing
/// that was recorded earlier.
///
/// TODO(BE): persisting the desktop key is not in this file and has one rule
/// that must not be got wrong. A read that *fails* says nothing about the
/// contents, so a store that falls through to "generate a new one" on an
/// unreadable file silently un-pairs every device — and the write succeeds, so
/// nothing downstream catches it. The store must refuse and surface the error.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'e2ee_wire.dart';

final _x25519 = X25519();

/// An X25519 key pair, with its public half already extracted.
class E2eeKeyPair {
  const E2eeKeyPair._(this._keyPair, this.publicKey, this.privateKey);

  /// A new random pair.
  static Future<E2eeKeyPair> generate() async =>
      _wrap(await _x25519.newKeyPair());

  /// The pair [privateKey] belongs to, for restoring a stored desktop key.
  static Future<E2eeKeyPair> fromPrivateKey(List<int> privateKey) async {
    if (privateKey.length != kE2eeKeyLength) {
      throw ArgumentError('private key must be $kE2eeKeyLength bytes');
    }
    return _wrap(await _x25519.newKeyPairFromSeed(privateKey));
  }

  final SimpleKeyPair _keyPair;

  /// The half that goes in the sealed record a phone reads.
  final Uint8List publicKey;

  /// The half that never leaves this machine. Held so a store can write it;
  /// treat every copy as the secret it is.
  final Uint8List privateKey;

  /// The 32 bytes both peers arrive at, for [deriveE2eeKeySchedule] to expand.
  ///
  /// Raw X25519 output, never used as a key directly — see
  /// `e2ee_key_schedule.dart`.
  Future<Uint8List> sharedSecretWith(List<int> peerPublicKey) async {
    if (peerPublicKey.length != kE2eeKeyLength) {
      throw ArgumentError('peer public key must be $kE2eeKeyLength bytes');
    }
    final secret = await _x25519.sharedSecretKey(
      keyPair: _keyPair,
      remotePublicKey: SimplePublicKey(peerPublicKey, type: KeyPairType.x25519),
    );
    return Uint8List.fromList(await secret.extractBytes());
  }

  static Future<E2eeKeyPair> _wrap(SimpleKeyPair keyPair) async {
    final publicKey = await keyPair.extractPublicKey();
    return E2eeKeyPair._(
      keyPair,
      Uint8List.fromList(publicKey.bytes),
      Uint8List.fromList(await keyPair.extractPrivateKeyBytes()),
    );
  }
}

/// 32 random bytes for a handshake nonce.
///
/// `Random.secure()` is the platform's own CSPRNG — `/dev/urandom` and its
/// equivalents — not the seeded generator `Random()` gives you. The difference
/// matters here: these nonces go into the HKDF salt, so a predictable one lets
/// an observer who knows the shared secret reproduce a session's keys.
Uint8List randomE2eeNonce() {
  final random = Random.secure();
  final nonce = Uint8List(kE2eeKeyLength);
  for (var i = 0; i < nonce.length; i++) {
    nonce[i] = random.nextInt(256);
  }
  return nonce;
}
