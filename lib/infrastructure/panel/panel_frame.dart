/// Framing for the USB link to the Grid Panel — turns a byte stream into
/// messages, and messages back into bytes.
///
/// A serial port hands over bytes, not messages, and the panel's port carries
/// bytes this code never wrote: the ESP32 ROM and the second-stage bootloader
/// print to it before the firmware is running at all. So the reader has to be
/// able to start mid-stream, discard whatever it cannot make sense of, and
/// find the next real frame in what is left.
///
/// The wire format, little-endian throughout:
///
/// ```text
/// A5 5A | ver:u8 | type:u8 | len:u16 | payload[len] | crc16:u16
/// ```
///
/// [kPanelMagic] is what the reader scans for; the CRC is what separates a
/// real frame from two bytes of boot noise that happened to look like the
/// magic. Without it, resync would land on garbage every 64 KB of noise or so
/// and hand the layer above a payload assembled out of nothing.
///
/// Deliberately free of Flutter and of `dart:io`: the same reason
/// `ConnectorBridge` is, which is that a protocol is checked by driving it
/// against the real thing from a scratch script, not by reading it.
library;

import 'dart:convert';
import 'dart:typed_data';

/// The two bytes every frame opens with, and the only thing the reader scans
/// for when it has lost its place.
const List<int> kPanelMagic = [0xA5, 0x5A];

/// The framing version this build speaks.
///
/// Bumped only when the *envelope* changes — the message vocabulary inside it
/// carries its own version in the `hello` handshake, so adding a message is
/// not a framing change.
const int kPanelFrameVersion = 1;

/// magic(2) + ver(1) + type(1) + len(2).
const int kPanelHeaderBytes = 6;

/// The trailing CRC-16.
const int kPanelCrcBytes = 2;

/// Largest payload a single frame may carry.
///
/// This is a bound on damage, not a capacity target: the largest thing the
/// link actually sends is a PCM chunk of about 1.3 KB. A corrupt length field
/// can claim up to 65535 bytes, and without a ceiling the reader would stall
/// waiting for a frame that is never coming while real frames pile up behind
/// it. Anything over this is treated as noise and resynced past.
const int kPanelMaxPayload = 8192;

/// What a frame's payload is.
///
/// A small closed set on purpose — an unknown code is not decoded into one of
/// these, it is reported as-is (see [PanelFrame.typeCode]) so a newer
/// firmware talking to an older app is a visible mismatch rather than a
/// silently mangled message.
enum PanelFrameType {
  /// A UTF-8 JSON control message.
  json(0x01),

  /// Raw 16-bit mono PCM, one chunk of a voice capture.
  pcm(0x02),

  /// One slice of a firmware image on its way to the device.
  ///
  /// A frame type rather than a JSON field because base64 in a control message
  /// would cost a third more bytes on a link that is already sending megabytes,
  /// and because the receiver writes these straight into flash without ever
  /// holding the whole image.
  firmware(0x03);

  const PanelFrameType(this.code);

  /// The byte written into the frame header.
  final int code;

  /// The type for [code], or null when this build does not know it.
  static PanelFrameType? fromCode(int code) {
    for (final type in values) {
      if (type.code == code) return type;
    }
    return null;
  }
}

/// One decoded frame.
///
/// Carries the raw [version] and [typeCode] rather than only the resolved
/// [type] so the layer above can tell "a message I don't know yet" from "a
/// corrupt frame" — the first deserves a clear mismatch error, the second is
/// already gone by the time it gets here.
class PanelFrame {
  const PanelFrame({
    required this.version,
    required this.typeCode,
    required this.payload,
  });

  /// A JSON control frame carrying [payload], at the current framing version.
  PanelFrame.json(String payload)
    : version = kPanelFrameVersion,
      typeCode = PanelFrameType.json.code,
      payload = Uint8List.fromList(utf8.encode(payload));

  final int version;
  final int typeCode;
  final Uint8List payload;

  /// The payload's type, or null when [typeCode] is one this build predates.
  PanelFrameType? get type => PanelFrameType.fromCode(typeCode);

  /// The payload decoded as UTF-8, for [PanelFrameType.json] frames.
  ///
  /// `allowMalformed` because a truncated multi-byte sequence should surface
  /// as a JSON parse error naming the message, not as an exception thrown from
  /// inside the decoder with no context.
  String get text => utf8.decode(payload, allowMalformed: true);

  @override
  String toString() =>
      'PanelFrame(v$version, type=0x${typeCode.toRadixString(16)}, '
      '${payload.length}B)';
}

/// CRC-16/CCITT-FALSE over `bytes[start..end)` — poly 0x1021, init 0xFFFF,
/// no reflection, no final xor.
///
/// Chosen because it is the one 16-bit CRC that is unambiguous by name and
/// short enough to hand-write identically on both sides; the C half of this
/// link implements the same loop, and both are checked against one shared
/// vector file.
int panelCrc16(List<int> bytes, {int start = 0, int? end}) {
  var crc = 0xFFFF;
  final stop = end ?? bytes.length;
  for (var i = start; i < stop; i++) {
    crc ^= (bytes[i] & 0xFF) << 8;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1;
      crc &= 0xFFFF;
    }
  }
  return crc;
}

/// Wrap [payload] in a frame of [type].
///
/// Throws [ArgumentError] when the payload is over [kPanelMaxPayload]: a
/// caller that builds an oversized message has a bug the reader on the other
/// end could only report as noise, so it is worth failing where the bug is.
Uint8List encodePanelFrame(PanelFrameType type, List<int> payload) {
  if (payload.length > kPanelMaxPayload) {
    throw ArgumentError.value(
      payload.length,
      'payload',
      'over the $kPanelMaxPayload-byte frame limit',
    );
  }
  final frame = Uint8List(kPanelHeaderBytes + payload.length + kPanelCrcBytes);
  frame[0] = kPanelMagic[0];
  frame[1] = kPanelMagic[1];
  frame[2] = kPanelFrameVersion;
  frame[3] = type.code;
  frame[4] = payload.length & 0xFF;
  frame[5] = (payload.length >> 8) & 0xFF;
  frame.setRange(
    kPanelHeaderBytes,
    kPanelHeaderBytes + payload.length,
    payload,
  );
  // Covers ver..payload — the magic is a marker, not data, and including a
  // constant would add nothing to detect.
  final crc = panelCrc16(
    frame,
    start: 2,
    end: kPanelHeaderBytes + payload.length,
  );
  frame[frame.length - 2] = crc & 0xFF;
  frame[frame.length - 1] = (crc >> 8) & 0xFF;
  return frame;
}

/// Encode a JSON control message.
Uint8List encodePanelJson(String json) =>
    encodePanelFrame(PanelFrameType.json, utf8.encode(json));

/// Reassembles frames from a byte stream that may start anywhere and contain
/// anything.
///
/// Stateful by necessity: a serial read returns whatever bytes happened to
/// have arrived, so a frame routinely spans two reads and two frames routinely
/// arrive in one. Feed every chunk in order and take the frames back.
class PanelFrameDecoder {
  /// Bytes seen but not yet resolved into a frame — a partial frame at the
  /// tail, plus at most one leading byte kept in case it opens a split magic.
  final List<int> _pending = [];

  /// Frames dropped because their CRC did not check out.
  ///
  /// Exposed because the number mattering is the *rate*: one at startup is the
  /// bootloader's parting bytes and is expected, while a steady trickle during
  /// a session means the two sides disagree about the format or the cable is
  /// bad — two very different problems that look identical without a count.
  int get corruptFrames => _corruptFrames;
  int _corruptFrames = 0;

  /// Bytes discarded while hunting for a frame boundary.
  int get discardedBytes => _discardedBytes;
  int _discardedBytes = 0;

  /// Feed [chunk] and take whatever frames are now complete, in order.
  ///
  /// Never throws: everything that arrives on this port is untrusted, and the
  /// only useful response to a byte that makes no sense is to step over it.
  List<PanelFrame> feed(List<int> chunk) {
    _pending.addAll(chunk);
    final frames = <PanelFrame>[];
    while (true) {
      final frame = _takeFront();
      if (frame == null) break;
      frames.add(frame);
    }
    return frames;
  }

  /// Forget any partial frame.
  ///
  /// Called when the port is reopened: the bytes left over belong to a session
  /// that has ended, and carrying them across would put a stale half-frame in
  /// front of the new device's first real one.
  /// The counters deliberately survive. They exist to show a *trend* — a
  /// handful of discarded bytes at every boot is the bootloader and is expected,
  /// while a steady trickle means the two sides disagree about the format or the
  /// cable is bad. Zeroing them on every reconnect would erase exactly the
  /// history that tells those two apart, and a link that reconnects often is
  /// precisely the one worth measuring.
  void reset() => _pending.clear();

  /// Decode one frame off the front, or null when more bytes are needed.
  ///
  /// Returns null for "wait", and loops internally for "that was noise" — so
  /// a caller can treat null as "nothing more to be had right now" without
  /// having to know which of the two happened.
  PanelFrame? _takeFront() {
    while (true) {
      final magic = _indexOfMagic();
      if (magic < 0) {
        // Nothing here opens a frame. Keep only a trailing byte that could be
        // the first half of a magic split across two reads.
        final keep = _pending.isNotEmpty && _pending.last == kPanelMagic[0]
            ? 1
            : 0;
        _discard(_pending.length - keep);
        return null;
      }
      if (magic > 0) _discard(magic);
      if (_pending.length < kPanelHeaderBytes) return null;

      final length = _pending[4] | (_pending[5] << 8);
      // A length this large cannot be real, so those two bytes were noise
      // rather than a header. Step over the magic and keep hunting — waiting
      // for 64 KB that will never arrive would stall the link.
      if (length > kPanelMaxPayload) {
        _resync();
        continue;
      }

      final total = kPanelHeaderBytes + length + kPanelCrcBytes;
      if (_pending.length < total) return null;

      final end = kPanelHeaderBytes + length;
      final expected = _pending[total - 2] | (_pending[total - 1] << 8);
      if (panelCrc16(_pending, start: 2, end: end) != expected) {
        // Drop one byte rather than the whole frame: the magic may have been a
        // coincidence inside noise, and a genuine frame can begin one byte in.
        _corruptFrames++;
        _resync();
        continue;
      }

      final frame = PanelFrame(
        version: _pending[2],
        typeCode: _pending[3],
        payload: Uint8List.fromList(_pending.sublist(kPanelHeaderBytes, end)),
      );
      _pending.removeRange(0, total);
      return frame;
    }
  }

  /// Offset of the next complete magic in [_pending], or -1.
  ///
  /// Stops one short of the end on purpose: a final lone byte cannot be judged
  /// yet, and the caller keeps it in case the next read completes the pair.
  int _indexOfMagic() {
    for (var i = 0; i + 1 < _pending.length; i++) {
      if (_pending[i] == kPanelMagic[0] && _pending[i + 1] == kPanelMagic[1]) {
        return i;
      }
    }
    return -1;
  }

  /// Step past one byte of a magic that did not lead anywhere.
  void _resync() => _discard(1);

  void _discard(int count) {
    if (count <= 0) return;
    _pending.removeRange(0, count);
    _discardedBytes += count;
  }
}
