import 'dart:typed_data';
import 'dart:ui' as ui;

import 'image_budget.dart';
import 'playground_request.dart';

/// Shrinks [image] until it fits [budgetBytes], or reports that it can't.
///
/// A picture is sent inside the request body as base64 text, so a phone photo
/// or a 5K screenshot is enough on its own to push a message past what the
/// relay accepts — and the reply that came back for it, `Request body exceeds
/// 20000000 bytes`, told the user nothing they could act on. Resizing here
/// means the ordinary case (a big screenshot) just works.
///
/// Returns [image] untouched when it already fits, a re-encoded PNG when
/// shrinking got it under the budget, and null when nothing did — a picture
/// Flutter can't decode, or one still too big at [kImageShrinkSteps]' smallest
/// step. The caller says so rather than sending a request that will be refused.
Future<MediaAttachment?> fitImageToBudget(
  MediaAttachment image, {
  int budgetBytes = kMaxAttachmentBytes,
}) async {
  if (image.bytes.length <= budgetBytes) return image;

  final source = await _imageSize(image.bytes);
  if (source == null) return null;

  for (final side in kImageShrinkSteps) {
    final target = targetImageSize(
      width: source.width,
      height: source.height,
      longestSide: side,
    );
    // Already smaller than this step — a smaller one may still fit the budget.
    if (target == null) continue;
    final shrunk = await _redraw(image.bytes, target);
    if (shrunk == null) return null;
    if (shrunk.length <= budgetBytes) {
      return MediaAttachment(
        filename: pngFilename(image.filename),
        bytes: shrunk,
      );
    }
  }
  return null;
}

/// The pixel size of an encoded picture, without decoding the whole thing.
///
/// Null for anything Flutter's codecs can't read (an SVG dropped in as a
/// picture, a truncated download) — there is nothing to resize there.
Future<({int width, int height})?> _imageSize(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return (width: descriptor.width, height: descriptor.height);
  } on Object {
    return null;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// Decodes [bytes] straight to [size] and re-encodes it as PNG.
///
/// The decoder does the scaling itself, so the full-size bitmap is never held
/// in memory — a 6000×4000 photo would be 96 MB of it.
Future<Uint8List?> _redraw(
  Uint8List bytes,
  ({int width, int height}) size,
) async {
  try {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: size.width,
      targetHeight: size.height,
    );
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    return data?.buffer.asUint8List();
  } on Object {
    return null;
  }
}
