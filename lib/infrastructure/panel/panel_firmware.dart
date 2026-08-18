/// The firmware image this build carries, and how it is cut up for the cable.
///
/// The app ships the image its own build was compiled against so the two halves
/// cannot drift: `hello` reports what the panel is running, and anything else
/// gets offered a replacement over the cable it is already talking on
/// (`docs/protocol.md` §2, Firmware update).
///
/// Free of Flutter — loading the asset needs it, so that half lives in
/// `panel_firmware_provider.dart`, the same split `panel_link_provider.dart`
/// makes. What is left here is pure and tested.
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'panel_frame.dart';

/// Where an ESP-IDF application image states what it is.
///
/// An `esp_image_header_t` is 24 bytes and the first segment header is 8, so
/// the `esp_app_desc_t` that IDF places at the top of the first segment starts
/// at byte 32 of the file. The struct opens with a magic word, and its
/// `version[32]` field sits 16 bytes in, after `secure_version` and two
/// reserved words.
const int _appDescOffset = 32;
const int _appDescMagic = 0xABCD5432;
const int _versionOffset = _appDescOffset + 16;
const int _versionLength = 32;

/// The first byte of every ESP32 image.
const int _imageMagic = 0xE9;

/// The version an ESP-IDF image states about itself, or null when [image] is
/// not one.
///
/// Pure, and the reason nothing else records the version: see
/// [PanelFirmwareImage.read].
String? esp32ImageVersion(Uint8List image) {
  if (image.length < _versionOffset + _versionLength) return null;
  if (image[0] != _imageMagic) return null;
  final header = ByteData.sublistView(image);
  if (header.getUint32(_appDescOffset, Endian.little) != _appDescMagic) {
    return null;
  }
  final field = image.sublist(_versionOffset, _versionOffset + _versionLength);
  // A fixed-width C string: everything from the first NUL is padding.
  final end = field.indexOf(0);
  final version = String.fromCharCodes(end < 0 ? field : field.sublist(0, end));
  return version.trim().isEmpty ? null : version.trim();
}

/// One firmware image, with the two facts the panel is offered it by.
class PanelFirmwareImage {
  const PanelFirmwareImage._({
    required this.bytes,
    required this.version,
    required this.sha256,
  });

  /// Read an image, taking its version out of the image itself.
  ///
  /// Null when the bytes are not an ESP-IDF application image — a truncated
  /// copy, a placeholder, a build that never finished. Nothing is offered in
  /// that case, which is the right answer: an image the app cannot even read
  /// the version of is not one to flash a device with.
  ///
  /// **Why the version is not recorded beside the bytes.** The obvious places —
  /// a const in Dart, a line in `pubspec.yaml`, a sidecar JSON written by the
  /// copy script — all share one flaw: they are edited or generated separately
  /// from the binary, so they can name a version the bytes are not. That
  /// mistake is invisible here and expensive there. It reads as "the panel
  /// keeps re-offering the same update" or, worse, as an update that is never
  /// offered at all because the recorded version already matches what the
  /// device reports. Every ESP-IDF image already carries `esp_app_desc_t`, so
  /// the one source that cannot disagree with the bytes is the bytes.
  ///
  /// The other half of that contract is on the device: `hello.fw` must be
  /// `esp_app_get_description()->version`, the same field read here. A
  /// hand-maintained macro reports a number nothing checks, and the two would
  /// disagree forever with no way to tell from this side.
  static PanelFirmwareImage? read(Uint8List bytes) {
    final version = esp32ImageVersion(bytes);
    if (version == null) return null;
    return PanelFirmwareImage._(
      bytes: bytes,
      version: version,
      // The device verifies this over what it actually wrote to flash and keeps
      // running the old image when it does not match, so it is the one check
      // that makes a bad transfer cost a reboot instead of a bricked panel.
      sha256: crypto.sha256.convert(bytes).toString(),
    );
  }

  final Uint8List bytes;

  /// What the image says it is — compared against `hello.fw`.
  final String version;

  /// Lower-case hex digest of the whole image, sent in `fw.offer`.
  final String sha256;

  int get size => bytes.length;
}

/// The image cut into frame-sized slices, in order from offset 0.
///
/// Views rather than copies: a megabyte of firmware sliced into 150 pieces
/// should not be a second megabyte of garbage. Throws [ArgumentError] on a
/// [limit] a frame could not carry, because that is a caller's bug and the
/// alternative is a frame the encoder refuses one slice into the transfer.
List<Uint8List> panelFirmwareSlices(
  Uint8List image, {
  int limit = kPanelMaxPayload,
}) {
  if (limit <= 0 || limit > kPanelMaxPayload) {
    throw ArgumentError.value(limit, 'limit', 'not a payload a frame can hold');
  }
  final slices = <Uint8List>[];
  for (var start = 0; start < image.length; start += limit) {
    final end = start + limit;
    slices.add(
      Uint8List.sublistView(image, start, end > image.length ? null : end),
    );
  }
  return slices;
}
