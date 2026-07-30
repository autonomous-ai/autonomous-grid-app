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

/// Why a typed MCP server URL can't be used, or null when it can.
///
/// Written to be read by someone who has never thought about URL schemes: it
/// names what to do rather than what is malformed. "Not a valid URI" tells a
/// person nothing they can act on.
///
/// **https only, and not as pedantry.** The address is where the assistant will
/// send whatever a tool call contains, and the app writes a bearer credential
/// into the headers going with it. Over `http` both cross the network in the
/// clear, and neither the user nor Grid would ever know. Localhost is no
/// exception here — this field is for a server "on the web"; a local one is a
/// command, which is the other half of this dialog.
///
/// Returns null for an empty string: nothing typed yet is not an error, and a
/// field that turns red on the first keystroke is a field people fight.
String? mcpUrlProblem(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;

  // Checked before parsing, because `Uri` does not reject a space — it
  // percent-encodes it into the host, so `https:// x .com` parses "fine" with a
  // host of `%20x%20.com`. Pasting an address with a word stuck to it is the
  // common way to get here, and it is worth naming rather than folding into the
  // generic message.
  if (RegExp(r'\s').hasMatch(text)) {
    return "A web address can't contain spaces — check for a stray space in "
        'what was pasted.';
  }

  final uri = Uri.tryParse(text);
  // A bare word parses fine as a relative reference, so "has a scheme" is the
  // real test — `Uri.tryParse('notion')` succeeds and has none.
  if (uri == null || uri.scheme.isEmpty || uri.host.isEmpty) {
    return 'That doesn\'t look like a web address. It should look like '
        'https://mcp.example.com/mcp';
  }

  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'http') {
    return 'Use https instead of http — an http address would send your data, '
        'and the key that unlocks it, unencrypted.';
  }
  if (scheme != 'https') {
    return 'Only https addresses work here. Change $scheme:// to https://';
  }
  return null;
}
