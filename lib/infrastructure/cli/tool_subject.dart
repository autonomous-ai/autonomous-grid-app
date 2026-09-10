/// What a tool call is *about*, read off its arguments — shared by every lane
/// that draws a connector's call, so the same MCP tool reads the same way
/// whether Claude Code or Codex made it.
library;

/// The arguments that say what a connector's call is about, in the order
/// they win. Measured, not borrowed: connector calls on this machine carried
/// `repo`, `target`, `direction`, `query`, `scope`, `topic` and `url` over a
/// month, and only these five name a subject — the rest are options.
const List<String> kConnectorSubjectKeys = [
  'query',
  'target',
  'url',
  'topic',
  'repo',
];

/// The first of [keys] that [input] fills with something readable — text or
/// a number. Never a list or a map, which would print as `[a, b]`.
String toolSubject(Map<String, dynamic> input, List<String> keys) {
  for (final key in keys) {
    final text = switch (input[key]) {
      final String value => value.trim(),
      final num value => '$value',
      _ => '',
    };
    if (text.isNotEmpty) return text;
  }
  return '';
}

/// A connector's call as `server · tool · subject`, rather than its wire
/// identifier: `mcp__plugin_playwright_playwright__browser_navigate` is one
/// real row, and a line of that spends its whole width on plumbing nobody
/// chose by name.
String connectorLabel({
  required String server,
  required String tool,
  required Map<String, dynamic> input,
}) {
  final about = toolSubject(input, kConnectorSubjectKeys);
  return [
    if (server.isNotEmpty) server.replaceAll('_', ' '),
    if (tool.isNotEmpty) tool.replaceAll('_', ' '),
    if (about.isNotEmpty) about,
  ].join(' · ');
}
