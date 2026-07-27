/// OpenClaw ran but couldn't answer — turn its raw stderr into a line the user
/// can act on, while the raw text still goes to the log (§6).
///
/// OpenClaw is a Node CLI, so its most common non-answer isn't the grid at all
/// but the runtime. Under a Node it doesn't support it prints a multi-line hint
/// ending in a bare `nvm alias default 24`; the service used to surface only
/// that last line, so the chat showed a stray shell command with no context.
/// This reads what actually failed and says what to do about it.
String friendlyOpenClawError(String raw) {
  final lower = raw.toLowerCase();
  // The runtime refusing to start — too old, or Bun (no `node:sqlite`). One fix,
  // a supported Node, covers both, so both point there rather than at the grid.
  if ((lower.contains('node.js') && lower.contains('is required')) ||
      lower.contains('bun runtime is unsupported')) {
    return kOpenClawNodeUnsupported;
  }
  // OpenClaw names the problem on its first line and follows it with hints, so
  // the first non-empty line carries more than the last one the service saw.
  final detail = raw
      .split('\n')
      .map((line) => line.trim())
      .firstWhere((line) => line.isNotEmpty, orElse: () => '');
  return detail.isEmpty
      ? "OpenClaw couldn't finish. Try sending again."
      : "OpenClaw couldn't finish: $detail";
}

/// OpenClaw needs a newer Node.js than this computer runs. Developer-facing —
/// OpenClaw ships developer-only — so it names Node directly rather than hiding
/// it behind "the assistant".
const String kOpenClawNodeUnsupported =
    'OpenClaw needs a newer Node.js than this computer has (Node 24 is '
    'recommended). Update Node.js, then try again.';
