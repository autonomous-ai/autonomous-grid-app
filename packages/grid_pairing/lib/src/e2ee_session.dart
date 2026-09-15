/// One live encrypted channel between this process and the peer on the other
/// end of the socket.
///
/// The session owns the two things a frame codec cannot: which key goes which
/// way, and how far the counters have got. Everything it does is synchronous
/// and in-memory, so the socket layer above stays a thin pipe — read bytes,
/// call [openText] or [openBinary], hand the plaintext to the RPC layer.
///
/// **A failed open is fatal to the session, not to the frame.** The counters
/// are a strict sequence: once a frame fails, this side no longer knows where
/// in the stream it is, and trying the next one against the same counter is
/// how a gap becomes silent data loss. Callers close the socket on null.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'e2ee_frame.dart';
import 'e2ee_key_schedule.dart';
import 'e2ee_wire.dart';

/// A channel bound to one handshake.
class E2eeSession {
  E2eeSession._({
    required this.schedule,
    required Uint8List sendKey,
    required Uint8List receiveKey,
    required E2eeDirection sendDirection,
  }) : _sendKey = sendKey,
       _receiveKey = receiveKey,
       _sendDirection = sendDirection;

  /// The desktop's half of [schedule]: seals desktop-to-mobile, opens the
  /// other way.
  factory E2eeSession.desktop(E2eeKeySchedule schedule) => E2eeSession._(
    schedule: schedule,
    sendKey: schedule.desktopToMobileKey,
    receiveKey: schedule.mobileToDesktopKey,
    sendDirection: E2eeDirection.desktopToMobile,
  );

  /// The phone's half of [schedule].
  factory E2eeSession.mobile(E2eeKeySchedule schedule) => E2eeSession._(
    schedule: schedule,
    sendKey: schedule.mobileToDesktopKey,
    receiveKey: schedule.desktopToMobileKey,
    sendDirection: E2eeDirection.mobileToDesktop,
  );

  /// What this session was derived from.
  final E2eeKeySchedule schedule;

  final Uint8List _sendKey;
  final Uint8List _receiveKey;
  final E2eeDirection _sendDirection;

  var _outboundCounter = 0;
  var _inboundCounter = 0;

  /// Frames sealed so far. The next one carries this number.
  int get framesSent => _outboundCounter;

  /// Frames opened so far.
  int get framesReceived => _inboundCounter;

  /// [plaintext] sealed as a text frame, base64 for a WebSocket text message.
  ///
  /// Text rides base64 rather than a binary frame because the RPC layer above
  /// is JSON and some of the paths under it — a relay that logs, a proxy that
  /// re-frames — handle text and binary differently. Binary payloads such as
  /// terminal output take [sealBinary] and skip the 33% cost.
  String sealText(String plaintext) =>
      base64.encode(_seal(utf8.encode(plaintext), E2eePayloadKind.text));

  /// [payload] sealed as a binary frame.
  Uint8List sealBinary(List<int> payload) =>
      _seal(payload, E2eePayloadKind.binary);

  /// The text [frameB64] carried, or null when it is not the next frame this
  /// session expects.
  String? openText(String frameB64) {
    // Bound the decode itself: base64 of an oversized frame is 4/3 of it, and
    // there is no reason to materialise that before rejecting it.
    if (frameB64.length > (kE2eeMaxFrameBytes + 2) ~/ 3 * 4) return null;
    final Uint8List frame;
    try {
      frame = base64.decode(frameB64);
    } on FormatException {
      return null;
    }
    final plaintext = _open(frame, E2eePayloadKind.text);
    if (plaintext == null) return null;
    try {
      return utf8.decode(plaintext);
    } on FormatException {
      // Sealed by the real peer but not valid UTF-8, so the peer is not
      // speaking this protocol. Fail it exactly like a bad tag.
      return null;
    }
  }

  /// The bytes [frame] carried, or null when it is not the next frame.
  Uint8List? openBinary(List<int> frame) =>
      _open(frame, E2eePayloadKind.binary);

  Uint8List _seal(List<int> payload, E2eePayloadKind payloadKind) {
    final frame = sealE2eeFrame(
      payload: payload,
      key: _sendKey,
      sessionId: schedule.sessionId,
      direction: _sendDirection,
      payloadKind: payloadKind,
      counter: _outboundCounter,
    );
    _outboundCounter++;
    return frame;
  }

  Uint8List? _open(List<int> frame, E2eePayloadKind payloadKind) {
    final plaintext = openE2eeFrame(
      frame: frame,
      key: _receiveKey,
      sessionId: schedule.sessionId,
      direction: _sendDirection.opposite,
      payloadKind: payloadKind,
      expectedCounter: _inboundCounter,
    );
    if (plaintext == null) return null;
    _inboundCounter++;
    return plaintext;
  }
}
