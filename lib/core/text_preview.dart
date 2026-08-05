/// One line standing in for a whole answer — what a notification banner shows,
/// and what an unopened result row says it contains.
///
/// "Your task finished" tells the user nothing they didn't already schedule; the
/// first real sentence of the answer is the reason to open it. So this takes the
/// first non-empty line, strips the markdown that would read as punctuation out
/// of context (`#`, `*`, `-`, `>`), and cuts it to [maxChars] at a word boundary
/// rather than mid-word.
///
/// Empty when [text] says nothing — the caller shows the fact that it ran rather
/// than an empty quote.
String firstLinePreview(String text, {int maxChars = 120}) {
  final line = text
      .split('\n')
      .map(_withoutLeadingMarkup)
      .firstWhere((l) => l.isNotEmpty, orElse: () => '');
  if (line.length <= maxChars) return line;

  final cut = line.substring(0, maxChars);
  final lastSpace = cut.lastIndexOf(' ');
  // A line with no spaces worth cutting at (a URL, a path) is cut where it is:
  // better a truncated token than a banner that shows almost nothing.
  return '${lastSpace > maxChars ~/ 2 ? cut.substring(0, lastSpace) : cut}…';
}

/// Drop the markdown that opens a line, so a heading or a bullet doesn't arrive
/// in a banner as `## Here's your brief`.
String _withoutLeadingMarkup(String line) =>
    line.replaceFirst(_leadingMarkup, '').trim();

final _leadingMarkup = RegExp(r'^[\s>#*\-–—•]+');
