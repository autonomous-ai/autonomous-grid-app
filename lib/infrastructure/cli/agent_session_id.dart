import 'dart:convert';
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

/// What Codex records about itself on the first line of a rollout.
///
/// Only the three fields that identify *whose* session it is. The rest of that
/// line is the whole system prompt.
typedef CodexRolloutMeta = ({
  String? originator,
  String? cwd,
  String? sessionId,
});

/// The originator Codex writes when it is the terminal UI — the one this app
/// starts.
///
/// Measured across a day of this machine's own `~/.codex/sessions`: `codex-tui`
/// (the interactive CLI, ours), `codex_exec` (`codex exec`, the one-shot lane
/// and any script), and `Codex Desktop` (the separate app, which writes into the
/// same folder from whatever project the user has open in it).
const String kCodexTuiOriginator = 'codex-tui';

/// Reads the identifying fields off a rollout's `session_meta` line.
///
/// Lenient on purpose: a line that is half-written, or a Codex build that names
/// its fields differently, reads as "can't tell" and costs a resume — never a
/// throw on a background poll.
CodexRolloutMeta? parseCodexRolloutMeta(String firstLine) {
  final Object? raw;
  try {
    raw = jsonDecode(firstLine);
  } on FormatException {
    return null;
  }
  if (raw is! Map || raw['type'] != 'session_meta') return null;
  final payload = raw['payload'];
  if (payload is! Map) return null;
  String? str(Object? v) => v is String && v.isNotEmpty ? v : null;
  return (
    originator: str(payload['originator']),
    cwd: str(payload['cwd']),
    sessionId: str(payload['session_id']) ?? str(payload['id']),
  );
}

/// Which of the rollouts that appeared belongs to the terminal this app just
/// opened in [workdir], or null when that cannot be said for certain.
///
/// **Codex cannot be told its session id**, so the app has to read back which
/// one it started. There is no flag, and `session_name` is not a config key —
/// `codex exec --strict-config -c session_name=x` answers `unknown configuration
/// field 'session_name'`. What every run does leave is a rollout named
/// `rollout-<ISO>-<uuid>.jsonl`, opening with a `session_meta` line.
///
/// **A new file is not enough, and assuming it was is why this failed three
/// times out of four on the machine it was written for.** That day's folder held
/// rollouts from three different programs — 10 `codex-tui`, 7 `codex_exec` and 4
/// `Codex Desktop`, the last from a separate app working in another project
/// entirely. Any of them landing inside the few seconds after a chat opens made
/// two files new instead of one, and the old rule refused them both.
///
/// So the candidates are narrowed by who wrote them ([kCodexTuiOriginator]) and
/// where they were working, and only then does one have to be alone. Still
/// ambiguous — two chats on the same folder opened in the same breath — answers
/// null and the chat starts fresh, because a wrong id is the failure that
/// doesn't look like one: the chat resumes, and answers out of a stranger's
/// conversation.
String? pickCodexSession({
  required Map<String, CodexRolloutMeta?> fresh,
  required String workdir,
}) {
  final mine = [
    for (final entry in fresh.entries)
      if (entry.value case final meta?)
        if (meta.originator == kCodexTuiOriginator && meta.cwd == workdir)
          entry,
  ];
  if (mine.length != 1) return null;
  // The line's own id first: the filename agrees today, and one of the two is
  // what Codex actually resumes by.
  return mine.first.value?.sessionId ?? codexSessionIdFromPath(mine.first.key);
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
