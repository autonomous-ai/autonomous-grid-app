/// What the user was looking at when they sent a turn, captured and carried
/// with it.
library;

/// Something on screen that went out with a message — today always a terminal,
/// captured the moment Send was pressed.
///
/// Kept beside the text rather than inside it, exactly as an attached file is:
/// the bubble shows a chip naming what rode along, while the model reads the
/// content (see `messageForModel`). A user's own sentence buried under two
/// hundred lines of build output is the version of this that made the
/// transcript unreadable.
class ChatContext {
  const ChatContext({
    required this.label,
    required this.detail,
    required this.text,
    this.truncated = false,
  });

  /// What the chip says — the panel tab's own title, e.g. `Terminal 2`.
  final String label;

  /// Where it was, for the header the model reads and the chip's tooltip: the
  /// folder the shell is running in.
  final String detail;

  /// The captured text, already cut to size by whoever captured it.
  final String text;

  /// Whether [text] starts part-way into what was on screen.
  final bool truncated;

  /// The block a model reads: a header saying what this is and where it came
  /// from, then the text. Same shape as an attached file's, so a turn carrying
  /// both doesn't arrive in two different formats.
  String get promptBlock => [
    '[$label — $detail]',
    '"""',
    text,
    '"""',
    if (truncated)
      '[Only the end of this is here; there is more above it in the terminal.]',
  ].join('\n');

  Map<String, dynamic> toJson() => {
    'label': label,
    'detail': detail,
    'text': text,
    if (truncated) 'truncated': true,
  };

  /// Reads one back from a saved conversation, or null when the entry has no
  /// text to show — a transcript written by an older build, or a hand-edited
  /// one, must not take the chat down with it.
  static ChatContext? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final text = raw['text'];
    if (text is! String || text.isEmpty) return null;
    final label = raw['label'];
    final detail = raw['detail'];
    return ChatContext(
      label: label is String && label.isNotEmpty ? label : 'Terminal',
      detail: detail is String ? detail : '',
      text: text,
      truncated: raw['truncated'] == true,
    );
  }
}
