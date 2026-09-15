/// Byte helpers the pairing tests share.
///
/// Deliberately not in `lib/`: hex is how a vector file spells bytes, and
/// nothing the app actually ships ever needs to read one.
library;

import 'dart:typed_data';

/// [length] copies of [byte].
///
/// Keys and nonces with an obvious shape, so a failure names which of the four
/// went wrong instead of printing two indistinguishable blobs.
Uint8List repeatedBytes(int byte, [int length = 32]) =>
    Uint8List(length)..fillRange(0, length, byte);

/// [length] bytes counting up from [first].
Uint8List countingBytes(int first, int length) =>
    Uint8List.fromList([for (var i = 0; i < length; i++) (first + i) & 0xff]);

/// [value] read as lowercase hex, the way a vector file spells bytes.
Uint8List hexBytes(String value) {
  final bytes = Uint8List(value.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = int.parse(value.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}

/// [bytes] written back the same way, so a mismatch prints as a diff.
String hexOf(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
