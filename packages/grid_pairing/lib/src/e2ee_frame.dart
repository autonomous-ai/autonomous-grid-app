/// Sealing and opening one frame on the phone link.
///
/// ```text
/// frame  = nonce(24) | XChaCha20-Poly1305(key, nonce, payload, aad: header)
/// header = sessionId(32) | direction(1) | payloadKind(1) | counter(u64 BE)
/// nonce  = sessionId[0..12] | 0x02 | direction | payloadKind | 0x00 | counter
/// ```
///
/// The header is **associated data**, not plaintext: it is authenticated but
/// never transmitted, because the receiver already knows every byte of it. Its
/// job is to make a frame refuse to open anywhere except the exact slot it was
/// sealed for — a frame replayed, reordered, reflected back at its sender, or
/// re-delivered as the other payload kind fails its tag rather than being
/// accepted. That is four attacks closed by one AEAD parameter.
///
/// The nonce is derived, never drawn: keys are fresh per socket and the
/// counter never repeats within one, so the fixed layout is already unique.
/// Drawing it randomly would add a collision risk for nothing. It still goes
/// on the wire, which costs 24 bytes a frame and buys a cheap reject before
/// the tag check plus a frame you can identify in a capture without the key.
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import 'e2ee_bytes.dart';
import 'e2ee_wire.dart';

/// Bytes of nonce on the front of every frame.
const kE2eeFrameNonceLength = 24;

/// Bytes of authenticated header behind every frame.
const kE2eeFrameHeaderLength = kE2eeKeyLength + 1 + 1 + 8;

/// Bytes of Poly1305 tag at the end of every frame.
const kE2eeFrameMacLength = 16;

/// Largest frame this side will try to open.
///
/// Mirrors the relay's own per-frame ceiling: accepting more here would only
/// let a peer spend this process's memory on something the path in front of it
/// would have dropped anyway.
const kE2eeMaxFrameBytes = 8 * 1024 * 1024;

const _cipher = DartXchacha20.poly1305Aead();

/// The authenticated header for one frame. Never transmitted.
Uint8List e2eeFrameHeader({
  required List<int> sessionId,
  required E2eeDirection direction,
  required E2eePayloadKind payloadKind,
  required int counter,
}) {
  _check(sessionId, counter);
  final header = Uint8List(kE2eeFrameHeaderLength);
  header.setRange(0, kE2eeKeyLength, sessionId);
  header[kE2eeKeyLength] = direction.wireByte;
  header[kE2eeKeyLength + 1] = payloadKind.wireByte;
  writeUint64Be(header, kE2eeKeyLength + 2, counter);
  return header;
}

/// The nonce for one frame, derived from the same four values as its header.
Uint8List e2eeFrameNonce({
  required List<int> sessionId,
  required E2eeDirection direction,
  required E2eePayloadKind payloadKind,
  required int counter,
}) {
  _check(sessionId, counter);
  final nonce = Uint8List(kE2eeFrameNonceLength);
  nonce.setRange(0, 12, sessionId);
  nonce[12] = kE2eeFraming;
  nonce[13] = direction.wireByte;
  nonce[14] = payloadKind.wireByte;
  nonce[15] = 0;
  writeUint64Be(nonce, 16, counter);
  return nonce;
}

/// [payload] sealed as the frame numbered [counter].
Uint8List sealE2eeFrame({
  required List<int> payload,
  required List<int> key,
  required List<int> sessionId,
  required E2eeDirection direction,
  required E2eePayloadKind payloadKind,
  required int counter,
}) {
  final nonce = e2eeFrameNonce(
    sessionId: sessionId,
    direction: direction,
    payloadKind: payloadKind,
    counter: counter,
  );
  final header = e2eeFrameHeader(
    sessionId: sessionId,
    direction: direction,
    payloadKind: payloadKind,
    counter: counter,
  );
  final sealed = _cipher.encryptSync(
    payload,
    secretKey: SecretKeyData(key),
    nonce: nonce,
    aad: header,
  );
  return concatBytes([nonce, sealed.cipherText, sealed.mac.bytes]);
}

/// [frame] opened as the frame numbered [expectedCounter], or null when it is
/// not that frame — wrong slot, wrong key, or tampered with.
///
/// One null for every rejection on purpose. A caller that could tell "bad tag"
/// from "wrong counter" would leak which of the two an attacker got right.
Uint8List? openE2eeFrame({
  required List<int> frame,
  required List<int> key,
  required List<int> sessionId,
  required E2eeDirection direction,
  required E2eePayloadKind payloadKind,
  required int expectedCounter,
}) {
  const overhead = kE2eeFrameNonceLength + kE2eeFrameMacLength;
  if (frame.length < overhead || frame.length > kE2eeMaxFrameBytes) return null;
  final nonce = e2eeFrameNonce(
    sessionId: sessionId,
    direction: direction,
    payloadKind: payloadKind,
    counter: expectedCounter,
  );
  if (!constantTimeEquals(frame.sublist(0, kE2eeFrameNonceLength), nonce)) {
    return null;
  }
  final header = e2eeFrameHeader(
    sessionId: sessionId,
    direction: direction,
    payloadKind: payloadKind,
    counter: expectedCounter,
  );
  try {
    return Uint8List.fromList(
      _cipher.decryptSync(
        SecretBox(
          frame.sublist(
            kE2eeFrameNonceLength,
            frame.length - kE2eeFrameMacLength,
          ),
          nonce: nonce,
          mac: Mac(frame.sublist(frame.length - kE2eeFrameMacLength)),
        ),
        secretKey: SecretKeyData(key),
        aad: header,
      ),
    );
  } on SecretBoxAuthenticationError {
    return null;
  }
}

void _check(List<int> sessionId, int counter) {
  if (sessionId.length != kE2eeKeyLength) {
    throw ArgumentError('session id must be $kE2eeKeyLength bytes');
  }
  if (counter < 0) {
    throw ArgumentError.value(counter, 'counter', 'must not be negative');
  }
}
