/// An `@`-mention being typed in the composer: where its `@` sits and the text
/// after it, so the menu can filter files and the pick can replace the token.
class FileMention {
  const FileMention({required this.start, required this.query});

  /// Index of the `@` in the composer text.
  final int start;

  /// The text between the `@` and the cursor — what the user is filtering by.
  final String query;
}

/// The `@`-mention under the cursor, or null when there isn't one.
///
/// A mention is an `@` that starts the text or follows whitespace, with no
/// whitespace between it and the cursor — `@rep` gives `rep`, a bare `@` gives
/// the empty string (show everything). An `@` mid-word (`a@b`, an email) or one
/// with a space after it isn't a mention, so the menu stays out of the way of
/// ordinary typing.
FileMention? activeMention(String text, int cursor) {
  if (cursor < 0 || cursor > text.length) return null;
  final before = text.substring(0, cursor);
  final at = before.lastIndexOf('@');
  if (at < 0) return null;
  // The '@' must open a token: at the start, or just after whitespace.
  if (at > 0 && !_isWhitespace(before[at - 1])) return null;
  final query = before.substring(at + 1);
  if (query.contains(RegExp(r'\s'))) return null;
  return FileMention(start: at, query: query);
}

/// Replace [mention]'s `@query` in [text] with [insert] plus a trailing space,
/// returning the new text and where the cursor lands (right after the space).
///
/// [cursor] is where the caret was — everything from [mention].start up to the
/// caret is the token being replaced; whatever followed the caret is kept.
({String text, int cursor}) applyMention(
  String text,
  int cursor,
  FileMention mention,
  String insert,
) {
  final replacement = '$insert ';
  final next = text.replaceRange(mention.start, cursor, replacement);
  return (text: next, cursor: mention.start + replacement.length);
}

bool _isWhitespace(String char) => char.trim().isEmpty;
