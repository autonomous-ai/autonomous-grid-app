import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'e2ee_test_bytes.dart';
import 'package:grid_pairing/grid_pairing.dart';

/// The frame layout is the whole defence on a link whose transport is plain
/// `ws://` on the LAN and an untrusted relay off it. Each of these is an
/// attack the header-as-associated-data closes, and each would be invisible if
/// it stopped working: the link would keep carrying traffic.
void main() {
  final key = repeatedBytes(0x11);
  final sessionId = repeatedBytes(0x22);
  final payload = Uint8List.fromList([1, 2, 3, 4, 5]);

  Uint8List seal({
    int counter = 0,
    E2eeDirection direction = E2eeDirection.mobileToDesktop,
    E2eePayloadKind payloadKind = E2eePayloadKind.text,
    List<int>? withKey,
  }) => sealE2eeFrame(
    payload: payload,
    key: withKey ?? key,
    sessionId: sessionId,
    direction: direction,
    payloadKind: payloadKind,
    counter: counter,
  );

  Uint8List? open(
    List<int> frame, {
    int expectedCounter = 0,
    E2eeDirection direction = E2eeDirection.mobileToDesktop,
    E2eePayloadKind payloadKind = E2eePayloadKind.text,
    List<int>? withKey,
  }) => openE2eeFrame(
    frame: frame,
    key: withKey ?? key,
    sessionId: sessionId,
    direction: direction,
    payloadKind: payloadKind,
    expectedCounter: expectedCounter,
  );

  test('a frame opens back to the bytes that went in', () {
    expect(open(seal()), payload);
  });

  test('an empty payload survives the round trip, so a zero-length terminal '
      'chunk is not mistaken for a failure', () {
    final frame = sealE2eeFrame(
      payload: const [],
      key: key,
      sessionId: sessionId,
      direction: E2eeDirection.mobileToDesktop,
      payloadKind: E2eePayloadKind.binary,
      counter: 0,
    );
    expect(open(frame, payloadKind: E2eePayloadKind.binary), isEmpty);
  });

  test('a captured frame replayed at the next counter is refused, so an '
      'attacker cannot make one request happen twice', () {
    final frame = seal();
    expect(open(frame), payload);
    expect(open(frame, expectedCounter: 1), isNull);
  });

  test('a frame delivered out of order is refused rather than accepted early, '
      'because a gap the receiver skips is silent data loss', () {
    expect(open(seal(counter: 2), expectedCounter: 1), isNull);
  });

  test('a frame reflected back at its own sender does not open, because each '
      'direction has its own key and its own header byte', () {
    final fromPhone = seal(direction: E2eeDirection.mobileToDesktop);
    expect(open(fromPhone, direction: E2eeDirection.desktopToMobile), isNull);
  });

  test('a text frame re-delivered as binary does not open, so terminal bytes '
      'can never surface as an RPC reply', () {
    final text = seal(payloadKind: E2eePayloadKind.text);
    expect(open(text, payloadKind: E2eePayloadKind.binary), isNull);
  });

  test('one flipped ciphertext byte is refused', () {
    final frame = seal();
    frame[frame.length - kE2eeFrameMacLength - 1] ^= 0x01;
    expect(open(frame), isNull);
  });

  test('one flipped tag byte is refused', () {
    final frame = seal();
    frame[frame.length - 1] ^= 0x01;
    expect(open(frame), isNull);
  });

  test('a rewritten nonce is refused before the tag check, so a relay cannot '
      'renumber frames to hide a drop', () {
    final frame = seal();
    frame[kE2eeFrameNonceLength - 1] ^= 0x01;
    expect(open(frame), isNull);
  });

  test('a frame sealed under another key is refused', () {
    expect(open(seal(withKey: repeatedBytes(0x33))), isNull);
  });

  test('a truncated frame is refused instead of throwing, because the bytes '
      'come off a socket a peer controls', () {
    expect(open(seal().sublist(0, kE2eeFrameNonceLength + 4)), isNull);
    expect(open(const <int>[]), isNull);
  });

  test('a counter past 32 bits still round trips, so a long-lived session '
      'does not fail once it has sent four billion frames', () {
    const counter = 0x1FFFFFFFF;
    expect(open(seal(counter: counter), expectedCounter: counter), payload);
  });

  test('a negative counter or a wrong-length session id is a programming '
      'error, not a frame to reject', () {
    expect(
      () => e2eeFrameNonce(
        sessionId: sessionId,
        direction: E2eeDirection.mobileToDesktop,
        payloadKind: E2eePayloadKind.text,
        counter: -1,
      ),
      throwsArgumentError,
    );
    expect(
      () => e2eeFrameHeader(
        sessionId: repeatedBytes(0x22).sublist(0, 31),
        direction: E2eeDirection.mobileToDesktop,
        payloadKind: E2eePayloadKind.text,
        counter: 0,
      ),
      throwsArgumentError,
    );
  });
}
