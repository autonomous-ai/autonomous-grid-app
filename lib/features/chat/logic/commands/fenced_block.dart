/// Reading a fenced block an assistant wrote for the app rather than for the
/// user, and taking it back out of the reply.
///
/// Two of these exist — `grid-loop` paces a running loop, `grid-ask` relays what
/// the user asked for — and both need the same two things: find the blocks, and
/// leave the answer without them. The mechanics live here so the two cannot
/// drift into reading slightly different markdown.
library;

/// ```` ```<fence> … ``` ```` anywhere in [text], innards only.
///
/// Every match, in the order written: the caller decides which one wins (the
/// last, for a reply that showed the format before using it).
List<String> fencedBlocks(String text, String fence) =>
    _fenceOf(fence).allMatches(text).map((m) => m.group(1) ?? '').toList();

/// [text] with every ```` ```<fence> ``` ```` block gone.
///
/// Stripped from what gets stored rather than hidden by the renderer, so the
/// transcript that is saved, re-sent as history and exported is the clean one.
String withoutFencedBlocks(String text, String fence) {
  if (!text.contains(fence)) return text;
  return text.replaceAll(_fenceOf(fence), '').trimRight();
}

RegExp _fenceOf(String fence) => RegExp(
  '^[ \\t]*```[ \\t]*$fence[ \\t]*\\r?\\n(.*?)^[ \\t]*```[ \\t]*\$',
  multiLine: true,
  dotAll: true,
);
