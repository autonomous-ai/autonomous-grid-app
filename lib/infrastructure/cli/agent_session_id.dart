import 'dart:math';

/// A session id for an agent CLI that lets the app name the conversation before
/// the program has started one.
///
/// Claude Code takes `--session-id <uuid>` and holds the conversation under it,
/// so the app never has to go looking for what it was called: the next launch
/// passes `--resume <uuid>` and carries on. Measured on 2.1.243 — reusing
/// `--session-id` on a session that exists is refused outright
/// (`Session ID … is already in use`), which is why a stored id must switch to
/// `--resume` rather than being passed again.
///
/// It has to be a real v4 UUID and not merely a unique string: the CLI parses it
/// and names a file after it.
String newAgentSessionId([Random? random]) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  // Version 4, variant 1 — the two fields a parser checks.
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = [
    for (final b in bytes) b.toRadixString(16).padLeft(2, '0'),
  ].join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// The id of the Codex session that appeared between [before] and [after], or
/// null when the two say nothing useful.
///
/// **Codex cannot be told its session id**, so the app has to read back which
/// one it started. There is no flag, and `session_name` is not a config key —
/// `codex exec --strict-config -c session_name=x` answers `unknown configuration
/// field 'session_name'`. What it does leave behind is a rollout, named
/// `rollout-<ISO timestamp>-<uuid>.jsonl`, written when the process starts.
///
/// So this compares two listings of the rollup folder and takes the uuid off the
/// one path that is new.
///
/// **Two files means no answer, and that is deliberate.** The obvious
/// alternative — pick the newest by modification time — was measured on
/// 2026-08-25 and picked up a *different* chat's Codex, running in the app,
/// which had just appended to a rollout from half an hour earlier. A wrong id
/// here is the one failure that doesn't look like one: the chat resumes, and
/// answers out of a stranger's conversation. Nothing beats one unambiguous new
/// file, so anything else declines to guess and the chat starts fresh.
String? newCodexSessionId({
  required Set<String> before,
  required Set<String> after,
}) {
  final fresh = after.difference(before);
  if (fresh.length != 1) return null;
  return codexSessionIdFromPath(fresh.first);
}

/// Both separators, always: a path is split the same way whatever platform read
/// it, so a fixture recorded on one machine still parses on another.
final RegExp _pathSeparator = RegExp(r'[/\\]');

/// The uuid inside a rollout's filename, or null when the name isn't one.
///
/// The uuid is the tail rather than a field: the timestamp in the middle carries
/// `-` of its own (`rollout-2026-08-25T10-24-50-<uuid>.jsonl`), so splitting on
/// the separator finds the wrong piece.
String? codexSessionIdFromPath(String path) {
  final name = path.split(_pathSeparator).last;
  final match = RegExp(
    r'^rollout-.*-([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}'
    r'-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\.jsonl$',
  ).firstMatch(name);
  return match?.group(1);
}
