/// The name a computer answers to on the wire.
///
/// Derived from its long-lived public key rather than chosen, so it cannot be
/// claimed by anybody else and there is nothing to register: a phone that dials
/// this id and gets a different key back knows immediately, because the key is
/// what produced the id.
///
/// It is not a secret. It travels in the path a phone dials and it names a
/// computer, which is why the address it is dialled *at* lives in a sealed
/// record (`phone_locator.dart`) and this does not.
///
/// The field keeps its `relayHostId` spelling in both the handshake context and
/// the locator record. The relay it was named after is gone, but that field is
/// hashed into the transcript the cross-implementation vectors pin
/// (`test/vectors/e2ee_handshake.txt`), so renaming it would be a wire change
/// dressed up as tidying.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import 'e2ee_wire.dart';

/// Characters of a host id.
///
/// 96 bits of a SHA-256: no number of computers that will ever exist collides,
/// and it still fits in a URL path and a line of a log.
const kRelayHostIdChars = 16;

/// The host id [publicKey] owns.
String deriveRelayHostId(List<int> publicKey) {
  if (publicKey.length != kE2eeKeyLength) {
    throw ArgumentError('public key must be $kE2eeKeyLength bytes');
  }
  final digest = crypto.sha256.convert(publicKey).bytes;
  return base64Url
      .encode(digest)
      .replaceAll('=', '')
      .substring(0, kRelayHostIdChars);
}
