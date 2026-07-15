/// Turn the add-server form's free text into the shapes [McpServer] needs.
///
/// Kept as pure functions so the dialog stays dumb and the parsing — the part
/// that's easy to get subtly wrong (blank lines, missing `=`) — is unit-tested.
library;

/// One argument per line; blank lines are ignored so trailing newlines don't
/// become empty args. Args aren't trimmed internally — a path with a trailing
/// space is the user's business — but surrounding blank lines are dropped.
List<String> parseArgLines(String text) => [
  for (final line in text.split('\n'))
    if (line.trim().isNotEmpty) line.trim(),
];

/// `KEY=value` per line into a map. A line without `=` or with a blank key is
/// skipped; the value keeps everything after the first `=` (so `URL=a=b` works).
Map<String, String> parseEnvLines(String text) => _pairs(text, separator: '=');

/// `Header: value` per line into a map, same rules as [parseEnvLines] but split
/// on the first colon — the shape HTTP headers are written in.
Map<String, String> parseHeaderLines(String text) =>
    _pairs(text, separator: ':');

Map<String, String> _pairs(String text, {required String separator}) {
  final map = <String, String>{};
  for (final line in text.split('\n')) {
    if (line.trim().isEmpty) continue;
    final at = line.indexOf(separator);
    if (at <= 0) continue;
    final key = line.substring(0, at).trim();
    if (key.isEmpty) continue;
    map[key] = line.substring(at + 1).trim();
  }
  return map;
}
