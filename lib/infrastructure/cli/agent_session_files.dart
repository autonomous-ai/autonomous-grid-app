import 'dart:io';

import '../../core/grid_paths.dart';
import 'agent_session_id.dart';

/// Whether an agent CLI still holds a session this app wrote down.
///
/// **A stored id is a promise about another program's disk, and it is broken
/// often enough to check every time.** Claude Code writes
/// `~/.claude/projects/<cwd-slug>/<id>.jsonl` on the **first turn**, not at
/// start-up — measured on 2.1.245: a launch given `--session-id` and then
/// abandoned leaves no file at all — while the app writes the id down *before*
/// the process starts, because the id is the flag it starts with. So a chat
/// opened and never typed into ends up holding an id nothing answers to, and
/// the next launch runs `claude --resume <id>`, which prints
/// `No conversation found with session ID: <id>` and exits before the TUI
/// draws. What the user sees is a terminal that flashes and dies, forever:
/// nothing clears the id, so every reopen fails the same way. Codex's rollouts
/// go missing more ordinarily — deleted, or moved with `CODEX_HOME`.
///
/// Asked before the argv is built ([AgentTerminals.ensure]), so an id that has
/// gone stale costs one fresh conversation instead of a chat that can never be
/// opened again.
///
/// The roots are overridable so tests never read the user's real history.
class AgentSessionFiles {
  AgentSessionFiles({Directory? claudeRoot, Directory? codexRoot})
    : _claudeRoot =
          claudeRoot ?? Directory('${GridPaths.userHome}/.claude/projects'),
      _codexRoot = codexRoot ?? _codexSessionsDir(Platform.environment);

  /// `~/.claude/projects`, one directory per working folder.
  final Directory _claudeRoot;

  /// `$CODEX_HOME/sessions`, read the same way [CodexRollouts] reads it — the
  /// app never sets that variable, but a user who has moved their Codex home
  /// keeps their rollouts there.
  final Directory _codexRoot;

  static Directory _codexSessionsDir(Map<String, String> environment) {
    final home =
        environment['CODEX_HOME'] ??
        '${environment['HOME'] ?? environment['USERPROFILE'] ?? ''}/.codex';
    return Directory('$home/sessions');
  }

  /// Whether Claude Code can still resume [sessionId].
  ///
  /// Every project folder is tried rather than the one the slug rule would
  /// name: that rule replaces path separators, so it is lossy in both
  /// directions (see `SessionScanner`), and guessing it wrong would report a
  /// live session as gone and throw away the conversation.
  Future<bool> claudeHolds(String sessionId) async {
    if (sessionId.isEmpty) return false;
    try {
      await for (final project in _claudeRoot.list()) {
        if (project is! Directory) continue;
        if (File('${project.path}/$sessionId.jsonl').existsSync()) return true;
      }
    } on FileSystemException {
      // No `~/.claude` at all: nothing to resume, which is the same answer.
      return false;
    }
    return false;
  }

  /// Whether Codex can still resume [sessionId] — its rollout is named after
  /// it, so the id in the filename is the whole check.
  Future<bool> codexHolds(String sessionId) async {
    if (sessionId.isEmpty) return false;
    try {
      await for (final entry in _codexRoot.list(recursive: true)) {
        if (entry is! File) continue;
        if (codexSessionIdFromPath(entry.path) == sessionId) return true;
      }
    } on FileSystemException {
      return false;
    }
    return false;
  }
}
