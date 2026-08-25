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
  Future<bool> claudeHolds(String sessionId) async =>
      await claudeSession(sessionId) != null;

  /// Whether Codex can still resume [sessionId].
  Future<bool> codexHolds(String sessionId) async =>
      await codexSession(sessionId) != null;

  /// The file Claude Code keeps [sessionId] in, or null when it has none.
  ///
  /// Every project folder is tried rather than the one the slug rule would
  /// name: that rule replaces path separators, so it is lossy in both
  /// directions (see `SessionScanner`), and guessing it wrong would report a
  /// live session as gone and throw away the conversation.
  Future<File?> claudeSession(String sessionId) async {
    if (sessionId.isEmpty) return null;
    try {
      await for (final project in _claudeRoot.list()) {
        if (project is! Directory) continue;
        final file = File('${project.path}/$sessionId.jsonl');
        if (file.existsSync()) return file;
      }
    } on FileSystemException {
      // No `~/.claude` at all: nothing to resume, which is the same answer.
      return null;
    }
    return null;
  }

  /// The rollout Codex keeps [sessionId] in, or null when it has none — the
  /// file is named after the session, so the name is the whole check.
  Future<File?> codexSession(String sessionId) async {
    if (sessionId.isEmpty) return null;
    try {
      await for (final entry in _codexRoot.list(recursive: true)) {
        if (entry is! File) continue;
        if (codexSessionIdFromPath(entry.path) == sessionId) return entry;
      }
    } on FileSystemException {
      return null;
    }
    return null;
  }
}
