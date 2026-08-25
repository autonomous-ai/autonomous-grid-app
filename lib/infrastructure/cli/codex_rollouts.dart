import 'dart:convert';
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

  /// Watches for the rollout this app's terminal writes in [workdir], and
  /// answers with the session id inside it.
  ///
  /// **Codex does not write the file when it starts** — measured on 0.144.6:
  /// spawning the TUI and typing nothing left the folder untouched for 35
  /// seconds. The rollout arrives with the *first turn*, which is whenever the
  /// user gets round to it. A fixed window after the spawn therefore finds
  /// nothing at all, which is exactly how this shipped not working: the log said
  /// "could not tell which Codex session started" three times out of four.
  ///
  /// So it waits as long as the session does. [keepWaiting] is the caller's
  /// answer to "is this still the terminal you asked about" — false once the
  /// chat has closed it, switched agent, or restarted — and this stops with it
  /// rather than outliving the thing it is watching.
  ///
  /// Every new file is opened far enough to read its `session_meta` line, which
  /// is what tells this app's terminal apart from the other programs writing
  /// here — see [pickCodexSession]. Only paths are listed until then, so the
  /// wait costs one directory listing every [every] and nothing else.
  Future<String?> discover({
    required Set<String> before,
    required String workdir,
    required bool Function() keepWaiting,
    Duration every = const Duration(seconds: 3),
  }) async {
    while (keepWaiting()) {
      final fresh = (await snapshot()).difference(before);
      if (fresh.isNotEmpty) {
        final id = pickCodexSession(
          fresh: {for (final path in fresh) path: await _metaOf(path)},
          workdir: workdir,
        );
        if (id != null) return id;
      }
      await Future<void>.delayed(every);
    }
    return null;
  }

  /// The `session_meta` line at the head of [path], or null when it cannot be
  /// read yet.
  ///
  /// A rollout is caught the instant it is created, so the first poll often
  /// finds a file with nothing in it — that is a "not yet", not a failure, and
  /// the next poll a quarter-second later reads it.
  Future<CodexRolloutMeta?> _metaOf(String path) async {
    try {
      final line = await File(path)
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      return parseCodexRolloutMeta(line);
    } on Object {
      return null;
    }
  }
}
