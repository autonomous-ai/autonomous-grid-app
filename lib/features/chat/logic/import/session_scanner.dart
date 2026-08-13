import 'dart:convert';
import 'dart:io';

import '../../../../core/grid_paths.dart';
import '../../../agents/logic/agent_prompt.dart';
import 'parsed_session.dart';

/// One session found on disk, described well enough to choose from a list —
/// and *only* that well.
///
/// Listing must not read the transcripts. The session files on this machine run
/// to megabytes each (4.2 MB for one Claude session, 3.7 MB for one Codex
/// rollout), and a screen that parsed a hundred of them to draw a hundred rows
/// would take seconds and hold the lot in memory to show a title. So everything
/// here comes from the file name, its stat, or the opening lines of the file.
class DiscoveredSession {
  const DiscoveredSession({
    required this.agent,
    required this.sessionId,
    required this.path,
    required this.title,
    required this.updatedAt,
    required this.sizeBytes,
    this.workdir,
    this.namedByTool = false,
  });

  final ImportedAgent agent;

  /// The tool's own id for the session — what `--resume` takes, and what the
  /// ledger keys on.
  final String sessionId;

  /// The `.jsonl` file itself.
  final String path;

  /// Best-effort name: the tool's own where the head of the file gave one up,
  /// else the opening line of the first thing the user said.
  final String title;

  /// Whether [title] is a name the *tool* chose — Claude Code's `ai-title`, or
  /// the thread name in Codex's session index — as opposed to a line this app
  /// derived from the transcript.
  ///
  /// The distinction decides whether the import may keep it. A tool's own name
  /// is the one the user last saw in that tool's list, and better than anything
  /// derivable. A derived line is a guess made from the *head* of the file,
  /// where both tools park their injected context — so the guess is often
  /// "The user opened the file …", and handing that to the parser as a
  /// preferred title overrode a perfectly good one built from the cleaned
  /// transcript.
  final bool namedByTool;

  /// The folder the session ran in, as the file reports it.
  final String? workdir;

  /// The file's own modification time — when the session was last talked in.
  final DateTime updatedAt;

  final int sizeBytes;

  /// The folder's own name, which is what a user recognises a project by. The
  /// full path is what identifies it; this is what fits on a row.
  String get folderName {
    final path = workdir;
    if (path == null || path.isEmpty) return '';
    final parts = path.split(Platform.pathSeparator)
      ..removeWhere((p) => p.isEmpty);
    return parts.isEmpty ? path : parts.last;
  }
}

/// Finds the sessions Claude Code and Codex have left on this computer.
///
/// Both directories are read-only to this app, always: they are another tool's
/// live state, and the one thing worse than failing to import a chat is
/// corrupting the file the other tool resumes from.
///
/// The roots are overridable so this can be pointed at a fixture directory
/// rather than at the user's real history.
class SessionScanner {
  SessionScanner({Directory? claudeRoot, Directory? codexRoot})
    : _claudeRoot =
          claudeRoot ?? Directory('${GridPaths.userHome}/.claude/projects'),
      _codexRoot = codexRoot ?? Directory('${GridPaths.userHome}/.codex');

  final Directory _claudeRoot;
  final Directory _codexRoot;

  /// How much of a file may be read to describe it.
  ///
  /// Generous, because a *line* can be enormous: one session on this machine
  /// opens with two 139-byte housekeeping lines and then a single 308 KB user
  /// message. Read through a 64 KB window it described itself as an untitled
  /// session in no folder — the facts were all there, three lines further in
  /// than the window reached. The reader below also stops the moment it has
  /// what it needs, so this ceiling is only ever paid by a file that never
  /// says.
  static const int _headBytes = 512 * 1024;

  /// A file smaller than this holds no conversation worth importing — a session
  /// opened and abandoned, or a header and nothing after it.
  static const int _minBytes = 200;

  /// Every session on this machine, newest first.
  ///
  /// Failures are per-file and silent by design: an unreadable session is one
  /// row missing from a list, while letting it throw would empty the screen and
  /// tell the user they have no history at all.
  Future<List<DiscoveredSession>> scan() async {
    final found = <DiscoveredSession>[
      ...await _scanClaude(),
      ...await _scanCodex(),
    ];
    found.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return found;
  }

  /// `~/.claude/projects/<cwd-slug>/<sessionId>.jsonl`.
  ///
  /// The directory name is the working directory with its separators replaced,
  /// which is lossy — a folder whose own name contains a dash is indistinguishable
  /// from a deeper path. So the folder is read from the `cwd` field *inside* the
  /// file instead, which is exact.
  Future<List<DiscoveredSession>> _scanClaude() async {
    final out = <DiscoveredSession>[];
    if (!_claudeRoot.existsSync()) return out;
    await for (final project in _claudeRoot.list()) {
      if (project is! Directory) continue;
      await for (final entry in project.list()) {
        if (entry is! File || !entry.path.endsWith('.jsonl')) continue;
        final session = await _describeClaude(entry);
        if (session != null) out.add(session);
      }
    }
    return out;
  }

  Future<DiscoveredSession?> _describeClaude(File file) async {
    try {
      final stat = await file.stat();
      if (stat.size < _minBytes) return null;
      final id = _basename(file.path).replaceAll('.jsonl', '');
      if (id.isEmpty) return null;

      String? workdir;
      String? title;
      String? firstUserLine;
      var startedHere = false;
      await for (final line in _head(file)) {
        final json = _decodeObject(line);
        if (json == null) continue;
        workdir ??= _string(json['cwd']);
        if (json['type'] == 'ai-title') {
          title = _string(json['aiTitle']) ?? title;
          continue;
        }
        if (firstUserLine == null &&
            json['type'] == 'user' &&
            json['isSidechain'] != true &&
            json['isMeta'] != true) {
          startedHere = _startedInThisApp(json['message']);
          firstUserLine = _openingLine(json['message']);
        }
        // Everything a row shows. The title Claude Code picked can be written
        // much later in the file — the full parse picks it up on import — so
        // waiting for it here would mean reading every session to the end.
        if (workdir != null && firstUserLine != null) break;
      }
      // A session this app opened by driving Claude Code in a project. It is
      // already a chat here, so offering it back would import a duplicate of a
      // conversation the user can see in their own sidebar — which is exactly
      // what the first build did: three rows, all titled "Project instructions
      // — follow these for everything you do in…", because that is the line
      // this app puts at the top of a project's opening turn.
      if (startedHere) return null;

      return DiscoveredSession(
        agent: ImportedAgent.claude,
        sessionId: id,
        path: file.path,
        title: title ?? firstUserLine ?? 'Untitled session',
        namedByTool: title != null,
        workdir: workdir,
        updatedAt: stat.modified,
        sizeBytes: stat.size,
      );
    } on FileSystemException {
      return null;
    }
  }

  /// `~/.codex/sessions/YYYY/MM/DD/rollout-<stamp>-<uuid>.jsonl`, with
  /// `~/.codex/session_index.jsonl` supplying the names.
  ///
  /// Codex keeps that index precisely so a list can be drawn without opening
  /// the rollouts, and it holds the thread name the user last saw — a better
  /// title than anything derivable from the transcript.
  Future<List<DiscoveredSession>> _scanCodex() async {
    final sessions = Directory('${_codexRoot.path}/sessions');
    if (!sessions.existsSync()) return const [];
    final names = await _codexThreadNames();

    final out = <DiscoveredSession>[];
    await for (final entry in sessions.list(recursive: true)) {
      if (entry is! File) continue;
      final name = _basename(entry.path);
      if (!name.startsWith('rollout-') || !name.endsWith('.jsonl')) continue;
      final session = await _describeCodex(entry, names);
      if (session != null) out.add(session);
    }
    return out;
  }

  Future<DiscoveredSession?> _describeCodex(
    File file,
    Map<String, String> names,
  ) async {
    try {
      final stat = await file.stat();
      if (stat.size < _minBytes) return null;

      String? id;
      String? workdir;
      String? firstUserLine;
      await for (final line in _head(file)) {
        final json = _decodeObject(line);
        final payload = json?['payload'];
        if (payload is! Map<String, dynamic>) continue;
        if (json!['type'] == 'session_meta') {
          id ??= _string(payload['session_id']);
          workdir ??= _string(payload['cwd']);
          continue;
        }
        if (json['type'] == 'turn_context') {
          workdir ??= _string(payload['cwd']);
          continue;
        }
        if (firstUserLine == null &&
            json['type'] == 'response_item' &&
            payload['type'] == 'message' &&
            payload['role'] == 'user') {
          firstUserLine = _openingLine(payload);
        }
        if (id != null && workdir != null && firstUserLine != null) break;
      }
      // No header means no id, and an id is the whole point — it is what the
      // ledger keys on and what `codex exec resume` takes.
      if (id == null) return null;

      // Sessions this app started itself, in the folder it made for them. They
      // are already chats here; offering them back would import a conversation
      // the user is looking at.
      if (workdir == GridPaths.agentWorkspaceDir.path) return null;

      return DiscoveredSession(
        agent: ImportedAgent.codex,
        sessionId: id,
        path: file.path,
        title: names[id] ?? firstUserLine ?? 'Untitled session',
        namedByTool: names.containsKey(id),
        workdir: workdir,
        updatedAt: stat.modified,
        sizeBytes: stat.size,
      );
    } on FileSystemException {
      return null;
    }
  }

  /// Codex's own thread names, by session id.
  Future<Map<String, String>> _codexThreadNames() async {
    final index = File('${_codexRoot.path}/session_index.jsonl');
    if (!index.existsSync()) return const {};
    try {
      final names = <String, String>{};
      for (final line in const LineSplitter().convert(
        await index.readAsString(),
      )) {
        final json = _decodeObject(line);
        if (json == null) continue;
        final id = _string(json['id']);
        final name = _string(json['thread_name']);
        // Later entries win: the index is appended to as a thread is renamed.
        if (id != null && name != null) names[id] = name;
      }
      return names;
    } on FileSystemException {
      return const {};
    }
  }

  /// The opening lines of [file], up to [_headBytes].
  ///
  /// A stream rather than a list so the caller can stop at the line that
  /// answers it — which for almost every file is the first one. Breaking out of
  /// an `await for` cancels the subscription, and the rest of the file is never
  /// read: that early exit is what keeps a scan of a few hundred sessions to a
  /// few hundred milliseconds despite the generous ceiling above.
  ///
  /// Decoded with `allowMalformed` because the byte cut lands mid-character on
  /// any file with non-ASCII in it. The trailing partial line is left in: it
  /// isn't valid JSON, so the caller's decode drops it a step later anyway, and
  /// tracking it here would mean buffering the whole read to find the end.
  Stream<String> _head(File file) => file
      .openRead(0, _headBytes)
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());

  /// Whether this app opened the session, rather than the tool's own CLI.
  ///
  /// Told by the header this app puts on a project chat's opening turn
  /// ([kProjectInstructionsHeader]) — the one thing in the file that could only
  /// have been written from here.
  ///
  /// It only catches sessions opened *inside a project*, which is the case that
  /// matters: a chat with no project runs in the app's own workspace folder,
  /// and that folder is not somewhere a user runs `claude` by hand.
  static bool _startedInThisApp(Object? message) {
    if (message is! Map<String, dynamic>) return false;
    final content = message['content'];
    final text = switch (content) {
      String() => content,
      List() => _firstText(content),
      _ => null,
    };
    return text != null && text.trimLeft().startsWith(kProjectInstructionsHeader);
  }

  /// The opening line of a message's text, clipped for a row.
  static String? _openingLine(Object? message) {
    if (message is! Map<String, dynamic>) return null;
    final content = message['content'];
    final text = switch (content) {
      String() => content,
      List() => _firstText(content),
      _ => null,
    };
    if (text == null) return null;
    // The same context blocks the parsers drop. Without this the row is titled
    // "The user opened the file …" for every session driven from an IDE, since
    // that block is injected *ahead* of the question it belongs to.
    final line = stripInjectedContext(
      text,
    ).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (line.isEmpty) return null;
    return line.length > 60 ? '${line.substring(0, 60).trimRight()}…' : line;
  }

  static String? _firstText(List<Object?> content) {
    for (final block in content) {
      if (block is! Map<String, dynamic>) continue;
      final type = block['type'];
      if (type != 'text' && type != 'input_text') continue;
      final text = block['text'];
      if (text is String && text.trim().isNotEmpty) return text;
    }
    return null;
  }

  static Map<String, dynamic>? _decodeObject(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  static String? _string(Object? raw) =>
      raw is String && raw.trim().isNotEmpty ? raw : null;

  static String _basename(String path) =>
      path.split(Platform.pathSeparator).last;
}
