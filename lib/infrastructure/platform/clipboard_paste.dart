import 'package:flutter/foundation.dart';
import 'package:pasteboard/pasteboard.dart';

/// What the clipboard is holding, as a composer cares about it.
///
/// Flutter's own `Clipboard` reads text and nothing else, so a screenshot — the
/// single most common thing a person pastes into a chat — arrived as an empty
/// paste: the keystroke did nothing and there was no way to tell why. This asks
/// the platform pasteboard for the picture and the files as well.
sealed class ClipboardPaste {
  const ClipboardPaste();
}

/// A picture with no file behind it — a screenshot, or an image copied out of a
/// browser. [filename] is ours to invent, since the clipboard carries none.
class PastedImage extends ClipboardPaste {
  const PastedImage({required this.bytes, required this.filename});

  final Uint8List bytes;
  final String filename;
}

/// Files copied in Finder / Explorer, by path.
class PastedFiles extends ClipboardPaste {
  const PastedFiles(this.paths);

  final List<String> paths;
}

/// Ordinary text — what the field would have pasted on its own.
class PastedText extends ClipboardPaste {
  const PastedText(this.text);

  final String text;
}

/// Nothing the composer can use.
class PastedNothing extends ClipboardPaste {
  const PastedNothing();
}

/// What a screenshot is called once it's attached. The clipboard hands over raw
/// PNG bytes with no name, and the transcript shows the path — so it says what
/// the file is rather than a number nobody chose.
const String kPastedImageFilename = 'pasted-image.png';

/// Reads the clipboard, richest thing first.
///
/// Files before the picture on purpose: copying a PNG in Finder can offer both,
/// and the file has a name, a size and a place on disk that the raw bytes don't.
Future<ClipboardPaste> readClipboardPaste() async {
  try {
    final files = await Pasteboard.files();
    if (files.isNotEmpty) return PastedFiles(files);

    final image = await Pasteboard.image;
    if (image != null && image.isNotEmpty) {
      return PastedImage(bytes: image, filename: kPastedImageFilename);
    }

    final text = await Pasteboard.text;
    if (text != null && text.isNotEmpty) return PastedText(text);
  } on Object catch (error) {
    // A clipboard we can't read is not worth an error card in the chat: the
    // keystroke does nothing, exactly as it did before, and the log carries why.
    debugPrint('Clipboard: could not read what is on it — $error');
  }
  return const PastedNothing();
}
