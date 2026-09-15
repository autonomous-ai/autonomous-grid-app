import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'e2ee_test_bytes.dart';
import 'package:grid_pairing/grid_pairing.dart';

/// Two sessions built from one schedule are the desktop and the phone. What
/// matters here is that they stay in step: the counters are the only thing
/// keeping a stream ordered once the frames are opaque.
void main() {
  E2eeKeySchedule schedule() => deriveE2eeKeySchedule(
    sharedSecret: repeatedBytes(5),
    transcript: utf8.encode('a transcript'),
    clientNonce: repeatedBytes(2),
    desktopNonce: repeatedBytes(4),
  );

  test('what the phone seals, the desktop opens, and the other way round', () {
    final shared = schedule();
    final phone = E2eeSession.mobile(shared);
    final desktop = E2eeSession.desktop(shared);

    expect(desktop.openText(phone.sealText('xin chao')), 'xin chao');
    expect(phone.openText(desktop.sealText('chao lai')), 'chao lai');
  });

  test('the desktop cannot open a frame it sealed itself, which is what stops '
      'a relay looping traffic back to make a peer answer itself', () {
    final shared = schedule();
    final desktop = E2eeSession.desktop(shared);
    final other = E2eeSession.desktop(shared);

    expect(other.openText(desktop.sealText('hello')), isNull);
  });

  test('text and binary share one counter, so a dropped terminal chunk breaks '
      'the next reply instead of being papered over', () {
    final shared = schedule();
    final phone = E2eeSession.mobile(shared);
    final desktop = E2eeSession.desktop(shared);

    final first = phone.sealText('one');
    phone.sealBinary(const [9, 9, 9]);
    final third = phone.sealText('three');

    expect(desktop.openText(first), 'one');
    // The binary frame never arrives. The next text frame is numbered 2 and
    // the desktop is still expecting 1, so it refuses rather than accepting a
    // stream with a hole in it.
    expect(desktop.openText(third), isNull);
  });

  test('counters advance only on success, so a caller that closes on the '
      'first null cannot be nudged into skipping a frame', () {
    final shared = schedule();
    final phone = E2eeSession.mobile(shared);
    final desktop = E2eeSession.desktop(shared);

    final good = phone.sealText('real');
    expect(desktop.openText('not base64 at all !!'), isNull);
    expect(desktop.framesReceived, 0);
    expect(desktop.openText(good), 'real');
    expect(desktop.framesReceived, 1);
  });

  test('sealing reports how many frames have gone out, for the diagnostics a '
      'stalled link is read from', () {
    final phone = E2eeSession.mobile(schedule());
    expect(phone.framesSent, 0);
    phone.sealText('one');
    phone.sealBinary(const [1]);
    expect(phone.framesSent, 2);
  });

  test('a correctly sealed text frame that is not UTF-8 fails like a bad tag, '
      'because a peer sending one is not speaking this protocol', () {
    final shared = schedule();
    final desktop = E2eeSession.desktop(shared);

    // Sealed by hand: `sealText` takes a String, so the only way to reach this
    // path is a peer that is not this code. 0xC3 opens a two-byte sequence
    // that never arrives.
    final frame = base64.encode(
      sealE2eeFrame(
        payload: const [0xC3],
        key: shared.mobileToDesktopKey,
        sessionId: shared.sessionId,
        direction: E2eeDirection.mobileToDesktop,
        payloadKind: E2eePayloadKind.text,
        counter: 0,
      ),
    );
    expect(desktop.openText(frame), isNull);
  });

  test('binary payloads round trip without going through base64', () {
    final shared = schedule();
    final phone = E2eeSession.mobile(shared);
    final desktop = E2eeSession.desktop(shared);

    final bytes = Uint8List.fromList(List.generate(4096, (i) => i & 0xff));
    expect(desktop.openBinary(phone.sealBinary(bytes)), bytes);
  });
}
