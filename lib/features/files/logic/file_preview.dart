import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'file_kind.dart';

/// The most a file may weigh before the panel refuses to read it.
///
/// A preview pane is not an editor: past this, laying the text out costs more
/// than looking at it is worth, and the user's own editor is one button away.
const int kFilePreviewMaxBytes = 1 << 20;

/// The most lines drawn from a file that clears [kFilePreviewMaxBytes].
///
/// The viewer lays its text out in one pass rather than virtualising, which is
/// what lets a whole file scroll and select as one block. This is the cap that
/// keeps that pass cheap. A file cut here says so.
const int kFilePreviewMaxLines = 2000;

/// The most an image may weigh before the panel refuses to draw it.
///
/// Its own ceiling, well above [kFilePreviewMaxBytes]: a screenshot out of a
/// repository is routinely past a megabyte, and refusing it would mean the
/// image cap was really a rule about text applied to something else. What the
/// number guards is the decode — bytes on disk become width × height × 4 in
/// memory — so it is generous rather than unlimited.
const int kImagePreviewMaxBytes = 16 << 20;

/// How much of the head is sniffed for the NUL byte that means "not text".
const int _sniffBytes = 8192;

/// What the panel can show for one file.
sealed class FilePreview {
  const FilePreview();
}

/// Text, ready to draw. [truncated] when the file went past
/// [kFilePreviewMaxLines] and [lines] is only its head.
class FilePreviewText extends FilePreview {
  FilePreviewText({required List<String> lines, required this.truncated})
    : lines = List.unmodifiable(lines);

  final List<String> lines;
  final bool truncated;
}

/// A picture, ready to draw, still in the bytes it was stored in.
///
/// Undecoded on purpose: the widget layer owns the decode, so the engine's
/// image cache holds the frame and the panel holds nothing but the file. For a
/// [vector] the same bytes are also its source, which is what lets the viewer
/// offer both forms without reading the file twice.
class FilePreviewImage extends FilePreview {
  const FilePreviewImage({required this.bytes, required this.vector});

  final Uint8List bytes;

  /// SVG — drawn by `flutter_svg` rather than by the engine's own codecs.
  final bool vector;
}

/// Not text and not a picture — an archive, a compiled thing.
class FilePreviewBinary extends FilePreview {
  const FilePreviewBinary();
}

/// Text, probably, but too heavy to lay out. Carries the size so the panel can
/// say *how* big rather than just "too big".
class FilePreviewTooBig extends FilePreview {
  const FilePreviewTooBig(this.bytes);

  final int bytes;
}

/// It couldn't be read at all — gone, or not ours to open.
class FilePreviewFailed extends FilePreview {
  const FilePreviewFailed(this.message);

  final String message;
}

/// Decide what [bytes] are, and cut them into lines if they're text.
///
/// Pure, so the three judgements this makes — binary or not, where to cut, what
/// counts as a line — can be tested without a filesystem.
///
/// Decoding is lenient (`allowMalformed`): a file that is *mostly* UTF-8 with a
/// stray byte in it is still worth reading, and the alternative is an exception
/// where the user expected their file.
FilePreview decodeFilePreview(Uint8List bytes) {
  final sniff = bytes.length < _sniffBytes ? bytes.length : _sniffBytes;
  for (var i = 0; i < sniff; i++) {
    if (bytes[i] == 0) return const FilePreviewBinary();
  }

  final text = utf8.decode(bytes, allowMalformed: true);
  // A trailing newline ends the last line rather than starting an empty one —
  // otherwise every well-formed file shows a phantom line at the bottom.
  final body = text.endsWith('\n') ? text.substring(0, text.length - 1) : text;
  final lines = body.isEmpty ? <String>[] : body.split('\n');

  if (lines.length <= kFilePreviewMaxLines) {
    return FilePreviewText(lines: lines, truncated: false);
  }
  return FilePreviewText(
    lines: lines.sublist(0, kFilePreviewMaxLines),
    truncated: true,
  );
}

/// One file's contents, for the Files panel.
///
/// `autoDispose` for both reasons at once: holding every file the user has
/// clicked would keep a session's worth of source in memory, and — the one that
/// matters — the assistant rewrites these files while they are on screen. A
/// cached read would quietly show yesterday's version of a file that changed a
/// second ago.
///
/// Never throws: every failure is a [FilePreviewFailed] the panel can put on
/// screen, because a file the user clicked that turns out to be unreadable is a
/// normal thing to happen in somebody else's folder.
final filePreviewProvider = FutureProvider.autoDispose
    .family<FilePreview, String>((ref, path) async {
      final file = File(path);
      try {
        final length = await file.length();
        // Decided by the name, before a byte is read: a picture is never text,
        // and sniffing it for a NUL would only reach the answer the extension
        // already gave — by the slow route, and wrongly for an SVG, which is
        // text and still not something to read as source by default.
        if (isImagePath(path)) {
          if (length > kImagePreviewMaxBytes) return FilePreviewTooBig(length);
          return FilePreviewImage(
            bytes: await file.readAsBytes(),
            vector: isSvgPath(path),
          );
        }
        if (length > kFilePreviewMaxBytes) return FilePreviewTooBig(length);
        return decodeFilePreview(await file.readAsBytes());
      } on FileSystemException catch (e) {
        return FilePreviewFailed(e.osError?.message ?? e.message);
      }
    });
