/// Turning one shared secret into the four values a session runs on.
///
/// The X25519 exchange gives both peers the same 32 bytes and nothing else.
/// Those bytes are used exactly once, as HKDF input keying material — never as
/// a key directly — so that the keys a session actually uses are bound to the
/// full handshake transcript and to both peers' nonces. Two consequences worth
/// naming: the desktop's long-lived key can open many sessions without any two
/// of them sharing a key, and a recorded session cannot be replayed into a
/// later one.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'e2ee_bytes.dart';
import 'e2ee_suite.dart';
import 'e2ee_wire.dart';

/// Bytes HKDF must produce: two directional keys and a session id.
const _kScheduleLength = 3 * kE2eeKeyLength;

/// What one handshake derives.
class E2eeKeySchedule {
  const E2eeKeySchedule({
    required this.mobileToDesktopKey,
    required this.desktopToMobileKey,
    required this.sessionId,
    required this.transcriptHash,
  });

  /// Seals what the phone sends; opens it on the desktop.
  final Uint8List mobileToDesktopKey;

  /// Seals what the desktop sends; opens it on the phone.
  final Uint8List desktopToMobileKey;

  /// Names this session inside every frame header and nonce. Also what the
  /// phone echoes to prove it derived the same schedule.
  final Uint8List sessionId;

  /// SHA-256 of the encoded handshake. Sent back in the authentication message
  /// so a mismatch surfaces as a refused login rather than as frames that
  /// silently fail to open.
  final Uint8List transcriptHash;
}

/// The schedule for one handshake.
///
/// [sharedSecret] is the raw X25519 output, [transcript] the encoded
/// handshake, and the two nonces the ones both peers exchanged in the clear.
E2eeKeySchedule deriveE2eeKeySchedule({
  required List<int> sharedSecret,
  required List<int> transcript,
  required List<int> clientNonce,
  required List<int> desktopNonce,
  E2eeSuite suite = E2eeSuite.grid,
}) {
  _requireLength(sharedSecret, kE2eeKeyLength, 'shared secret');
  _requireLength(clientNonce, kE2eeKeyLength, 'client nonce');
  _requireLength(desktopNonce, kE2eeKeyLength, 'desktop nonce');
  final transcriptHash = Uint8List.fromList(sha256.convert(transcript).bytes);
  final salt = sha256.convert(
    concatBytes([
      utf8.encode(suite.saltLabel),
      [E2eeSuite.labelTerminator],
      clientNonce,
      desktopNonce,
    ]),
  );
  final info = concatBytes([
    utf8.encode(suite.sessionLabel),
    [E2eeSuite.labelTerminator],
    transcriptHash,
  ]);
  final expanded = hkdfSha256(
    ikm: sharedSecret,
    salt: salt.bytes,
    info: info,
    length: _kScheduleLength,
  );
  return E2eeKeySchedule(
    mobileToDesktopKey: Uint8List.sublistView(expanded, 0, 32),
    desktopToMobileKey: Uint8List.sublistView(expanded, 32, 64),
    sessionId: Uint8List.sublistView(expanded, 64, 96),
    transcriptHash: transcriptHash,
  );
}

/// HKDF-SHA256 (RFC 5869): extract [ikm] under [salt], then expand to [length]
/// bytes under [info].
///
/// Written out rather than taken from `package:cryptography`, whose HKDF is
/// async-only. This is one `Hmac` composition, it keeps the whole key schedule
/// a pure synchronous function that a test can call without a harness, and
/// `test/pairing/e2ee_key_schedule_test.dart` pins it to the RFC's own vectors.
Uint8List hkdfSha256({
  required List<int> ikm,
  required List<int> salt,
  required List<int> info,
  required int length,
}) {
  if (length < 1 || length > 255 * 32) {
    throw ArgumentError.value(length, 'length', 'outside HKDF-SHA256 range');
  }
  final prk = Hmac(sha256, salt).convert(ikm).bytes;
  final output = Uint8List(length);
  var block = const <int>[];
  var offset = 0;
  for (var counter = 1; offset < length; counter++) {
    block = Hmac(sha256, prk).convert([...block, ...info, counter]).bytes;
    final take = block.length < length - offset
        ? block.length
        : length - offset;
    output.setRange(offset, offset + take, block);
    offset += take;
  }
  return output;
}

void _requireLength(List<int> bytes, int expected, String label) {
  if (bytes.length != expected) {
    throw ArgumentError('$label must be $expected bytes, got ${bytes.length}');
  }
}
