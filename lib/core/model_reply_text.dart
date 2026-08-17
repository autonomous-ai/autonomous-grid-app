/// Taking a model's answer back to the bare text a field wants.
///
/// Models wrap a one-line answer in the shapes prose is written in — a fence, a
/// "Title:" lead-in, quotation marks — however plainly they were asked not to.
/// Every caller that puts a model's reply straight into a field (a commit
/// message, a chat's name) meets the same shapes, so they strip them the same
/// way rather than each growing its own copy.
library;

/// Drops a ``` fence around the whole answer, whatever it was labelled.
String unfenceReply(String text) {
  if (!text.startsWith('```')) return text;
  final firstBreak = text.indexOf('\n');
  if (firstBreak == -1) return text;
  final end = text.lastIndexOf('```');
  final inner = end > firstBreak
      ? text.substring(firstBreak + 1, end)
      : text.substring(firstBreak + 1);
  return inner.trim();
}

/// Drops one matching pair of quotes wrapping [line].
///
/// Only when the pair wraps the *whole* line: quotation marks inside a sentence
/// belong to the sentence.
String unquoteLine(String line) {
  const pairs = [('"', '"'), ('“', '”'), ("'", "'"), ('`', '`')];
  for (final (open, close) in pairs) {
    if (line.length > 1 && line.startsWith(open) && line.endsWith(close)) {
      return line.substring(1, line.length - 1).trim();
    }
  }
  return line;
}
