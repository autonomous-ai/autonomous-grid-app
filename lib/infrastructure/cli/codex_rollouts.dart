import 'dart:io';

import 'agent_session_id.dart';

/// The folder Codex records its sessions in, and the one way to learn the id of
/// a session this app just started.
///
/// Codex takes no `--session-id` and has no config key for one (see
/// [newCodexSessionId]), so a chat that wants to carry on tomorrow has to read
/// back what today's process called itself. Every run writes
/// `rollout-<ISO>-<uuid>.jsonl` here as it starts, so the id is the difference
/// between a listing taken before the spawn and one taken after.
///
/// The directory is overridable so tests point at a temp dir and never read the
/// user's real Codex history.
class CodexRollouts {
  CodexRollouts({Directory? directory, Map<String, String>? environment})
    : _dir = directory ?? _sessionsDir(environment ?? Platform.environment);

  final Directory _dir;

  /// `$CODEX_HOME/sessions`, or `~/.codex/sessions`.
  ///
  /// `CODEX_HOME` is read rather than assumed away: the app never sets it (it
  /// would take the user's Codex credentials with it — see `AgentHomes`), but a
  /// user who has set it themselves keeps their sessions there, and a snapshot
  /// of the wrong folder would quietly find nothing and start fresh every time.
  static Directory _sessionsDir(Map<String, String> environment) {
    final home =
        environment['CODEX_HOME'] ??
        '${environment['HOME'] ?? environment['USERPROFILE'] ?? ''}/.codex';
    return Directory('$home/sessions');
  }

  /// Every rollout on disk right now.
  ///
  /// An unreadable or absent folder reads as "none", not as an error: Codex
  /// creates it on first run, and a chat opened before that must still start.
  Future<Set<String>> snapshot() async {
    try {
      return {
        await for (final entry in _dir.list(recursive: true))
          if (entry is File && codexSessionIdFromPath(entry.path) != null)
            entry.path,
      };
    } on FileSystemException {
      return const {};
    }
  }

  /// Waits for the one rollout that wasn't in [before], and answers with its id.
  ///
  /// Polled rather than watched: the folder is nested by date
  /// (`sessions/<y>/<m>/<d>/`), so a run that starts the first session of a day
  /// creates directories a recursive watch would have to be re-armed for, and
  /// this is a handful of `list()` calls over a few seconds either way.
  ///
  /// Null when nothing new appears inside [timeout], and null just as readily
  /// when *two* do — [newCodexSessionId] refuses to guess between them, and a
  /// chat that guesses wrong resumes a stranger's conversation.
  Future<String?> discover({
    required Set<String> before,
    Duration timeout = const Duration(seconds: 10),
    Duration every = const Duration(milliseconds: 250),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final id = newCodexSessionId(before: before, after: await snapshot());
      if (id != null) return id;
      await Future<void>.delayed(every);
    }
    return null;
  }
}
