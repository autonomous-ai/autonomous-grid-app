/// Byte helpers every layer of the phone link's encrypted channel shares.
///
/// Deliberately free of Flutter and of `dart:io`: the same reason
/// `PanelFrame` is. A wire format is checked by driving it against the other
/// implementation, and that is far easier when nothing here needs a binding.
library;

import 'dart:convert';
import 'dart:typed_data';

/// [value] decoded, or null unless it is *canonical* base64 of exactly
/// [length] bytes.
///
/// Canonical means re-encoding the bytes reproduces the input character for
/// character. This is not pedantry. A public key and a nonce arrive as text
/// and then enter the transcript hash as bytes, and base64's final character
/// carries spare bits — so two different strings decode to the same 32 bytes.
/// Accept both spellings and the two peers hash the same handshake to two
/// different values: the link dies at the first frame, with a decrypt failure
/// and nothing on either side pointing at the cause.
Uint8List? decodeCanonicalBase64(String value, int length) {
  final Uint8List bytes;
  try {
    bytes = base64.decode(value);
  } on FormatException {
    return null;
  }
  if (bytes.length != length) return null;
  return base64.encode(bytes) == value ? bytes : null;
}

/// Whether two byte strings match, in time that does not depend on how far in
/// they first differ.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

/// [value] as four big-endian bytes.
Uint8List uint32Be(int value) {
  final bytes = Uint8List(4);
  ByteData.view(bytes.buffer).setUint32(0, value, Endian.big);
  return bytes;
}

/// Writes [value] as eight big-endian bytes at [offset].
///
/// Written by hand rather than with `ByteData.setUint64`, which is not
/// implemented when Dart compiles to JavaScript. Nothing here needs the web
/// today, but a codec that quietly stops working on one target is a bad thing
/// to discover from a customer.
void writeUint64Be(Uint8List target, int offset, int value) {
  var remaining = value;
  for (var i = 7; i >= 0; i--) {
    target[offset + i] = remaining & 0xff;
    remaining >>= 8;
  }
}

/// [parts] joined into one buffer.
Uint8List concatBytes(List<List<int>> parts) {
  var total = 0;
  for (final part in parts) {
    total += part.length;
  }
  final result = Uint8List(total);
  var offset = 0;
  for (final part in parts) {
    result.setRange(offset, offset + part.length, part);
    offset += part.length;
  }
  return result;
}

/// One `name: value` pair, length-prefixed on both halves.
///
/// ```text
/// u32(len(utf8(name))) | utf8(name) | u32(len(value)) | value
/// ```
///
/// Used by every transcript this app hashes — the handshake's and the relay
/// host proof's. Self-delimiting rather than separated: joining fields with a
/// delimiter would let a value containing it forge a field boundary, so two
/// different inputs could encode to the same bytes and share a key.
Uint8List lengthPrefixedField(String name, List<int> value) {
  final encodedName = utf8.encode(name);
  return concatBytes([
    uint32Be(encodedName.length),
    encodedName,
    uint32Be(value.length),
    value,
  ]);
}

/// The fields [transcript] holds, or null when it is not well-formed.
///
/// Rejects a repeated name rather than letting the last one win: a transcript
/// that can say `relayOrigin` twice is a transcript where the value a reader
/// checks and the value a signer meant can differ.
Map<String, Uint8List>? parseLengthPrefixedFields(List<int> transcript) {
  final bytes = Uint8List.fromList(transcript);
  final view = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
  final fields = <String, Uint8List>{};
  var offset = 0;
  while (offset < bytes.length) {
    if (offset + 4 > bytes.length) return null;
    final nameLength = view.getUint32(offset, Endian.big);
    offset += 4;
    if (offset + nameLength + 4 > bytes.length) return null;
    final name = utf8.decode(
      bytes.sublist(offset, offset + nameLength),
      allowMalformed: true,
    );
    offset += nameLength;
    final valueLength = view.getUint32(offset, Endian.big);
    offset += 4;
    if (offset + valueLength > bytes.length || fields.containsKey(name)) {
      return null;
    }
    fields[name] = bytes.sublist(offset, offset + valueLength);
    offset += valueLength;
  }
  return offset == bytes.length ? fields : null;
}
