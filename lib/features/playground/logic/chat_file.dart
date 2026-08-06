/// A document attached to a chat turn: what it is, where it lives, and the text
/// the app managed to read out of it.
library;

/// How much text one attached file may put into a prompt, in characters.
///
/// A spreadsheet can hold more text than a model will take, and one attachment
/// must never crowd out the conversation it was attached to. What is cut is said
/// out loud in the prompt, with the path beside it, so an agent that needs the
/// rest can open the file itself.
const int kFileTextBudget = 20000;

/// A file the user attached to a turn — a document rather than a picture.
///
/// [path] is the original on this machine, never a copy: an agent asked to fix
/// the typos in a report has to edit the file the user meant, and it is also
/// where the parts we cut still live. [text] is what the app could read out of
/// it — Word/Excel/PowerPoint are zipped XML and plain files are read as they
/// are — so a model with no filesystem still gets the content. Null when nothing
/// readable came out (a scanned PDF, a legacy `.doc`, a file too big to read),
/// which the prompt then says plainly instead of pretending the file was read.
class ChatFile {
  const ChatFile({
    required this.path,
    required this.name,
    required this.sizeBytes,
    this.text,
    this.truncated = false,
  });

  final String path;
  final String name;

  /// The file's size on disk, for the chip that names it.
  final int sizeBytes;

  /// The text read out of the file, already capped at [kFileTextBudget]. Null or
  /// blank when the app couldn't read it.
  final String? text;

  /// Whether [text] stops short of the whole file.
  final bool truncated;

  /// Whether the app got any text out of this file.
  bool get isReadable => (text ?? '').trim().isNotEmpty;

  /// The file as a model reads it: a header naming it and where it lives, then
  /// its text. A file we couldn't read still goes in — the path is real, and an
  /// agent with file tools can open what the app couldn't.
  String get promptBlock {
    if (!isReadable) {
      return '[File attached: $name — $path. The app could not read any text '
          'out of it; open the file yourself if you can.]';
    }
    return [
      '[File attached: $name — $path]',
      '"""',
      text!.trim(),
      '"""',
      if (truncated) '[$name was cut short here — open the file for the rest.]',
    ].join('\n');
  }

  Map<String, dynamic> toJson() => {
    'path': path,
    'name': name,
    'size': sizeBytes,
    if (text != null) 'text': text,
    if (truncated) 'truncated': true,
  };

  /// Reads one back from a saved conversation, or null when the entry is not a
  /// file we can name — a transcript written by an older build, or a hand-edited
  /// one, must not take the chat down with it.
  static ChatFile? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final path = raw['path'];
    if (path is! String || path.isEmpty) return null;
    final name = raw['name'];
    final size = raw['size'];
    return ChatFile(
      path: path,
      name: name is String && name.isNotEmpty ? name : fileNameOf(path),
      sizeBytes: size is num ? size.toInt() : 0,
      text: raw['text'] is String ? raw['text'] as String : null,
      truncated: raw['truncated'] == true,
    );
  }
}

/// The last segment of [path], on either platform's separator.
String fileNameOf(String path) => path.split('/').last.split(r'\').last;

/// The lower-case extension of [name] without the dot, or an empty string when
/// it has none.
String fileExtensionOf(String name) {
  final base = fileNameOf(name);
  final dot = base.lastIndexOf('.');
  if (dot <= 0 || dot == base.length - 1) return '';
  return base.substring(dot + 1).toLowerCase();
}

/// A file size as a person reads it: `842 B`, `18 KB`, `2.4 MB`.
///
/// Decimal units, the same ones Finder shows, so the number beside a file in the
/// composer matches the one beside it on the desktop.
String formatFileSize(int bytes) {
  if (bytes < 1000) return '$bytes B';
  if (bytes < 1000 * 1000) return '${(bytes / 1000).round()} KB';
  final mb = bytes / (1000 * 1000);
  if (mb < 1000) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  return '${(mb / 1000).toStringAsFixed(1)} GB';
}
