import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'claude_exec_event.dart';
import 'claude_stream_parser.dart';
import 'host_environment.dart';

/// Thrown when a Claude Code turn can't even start (the binary won't launch).
class ClaudeExecException implements Exception {
  const ClaudeExecException(this.message, {this.retryable = true});

  final String message;

  /// Whether sending again could plausibly work. False for a machine that isn't
  /// set up: the same send fails the same way, so a retry only wastes the user's.
  final bool retryable;

  @override
  String toString() => 'ClaudeExecException: $message';
}

/// A single running Claude Code turn: its parsed events, a future that completes
/// when the process exits, and a kill switch.
///
/// Like Codex and unlike Hermes's persistent ACP session, each turn is its own
/// `claude -p` process that runs once and exits; continuity comes from resuming
/// the session, not from keeping the process alive.
class ClaudeExecRun {
  const ClaudeExecRun({
    required this.events,
    required this.done,
    required this.kill,
  });

  final Stream<ClaudeExecEvent> events;
  final Future<void> done;
  final void Function() kill;
}

/// Drives Claude Code as a chat agent over `claude -p`. Behind an interface so
/// the sender is tested against a fake that replays scripted turns.
abstract interface class ClaudeExecService {
  /// Run one turn. [resumeSessionId] continues an earlier conversation; null
  /// starts a fresh one. [workdir] is the folder the turn opens in, and
  /// [environment] carries the grid the answer comes from (see
  /// `claudeCodeEnv`). [mcpConfigPath] narrows the turn to the app's own
  /// connectors; null leaves it reading `~/.claude.json`. Throws
  /// [ClaudeExecException] if the process won't start.
  ClaudeExecRun run({
    required String workdir,
    required String prompt,
    required String model,
    required Map<String, String> environment,
    String? resumeSessionId,
    String? mcpConfigPath,
  });
}

/// How much of this computer a Claude Code turn may touch.
///
/// TODO(BE): `bypassPermissions` is exactly what it says — Claude writes files
/// and runs commands **anywhere on this machine, with nobody asked first**.
/// `claude -p` is non-interactive and has no per-action approval channel (the
/// thing Hermes gets over ACP), so there is no card, no prompt and no stopping
/// it mid-command; the only limits left are the ones the OS puts on the user
/// account. Chosen deliberately, to match what Codex already gets here — but it
/// is the widest grant in the app, so it is named here rather than buried in an
/// argv string. `acceptEdits` is the one-word change that would take shell
/// commands back out of it.
const String kClaudePermissionMode = 'bypassPermissions';

// Removed 2026-08-04: `kClaudeToolSearchPrompt`, an `--append-system-prompt`
// telling the model its MCP tools were hidden behind `ToolSearch`.
//
// It was added on the finding that "Claude Code never puts MCP tools in the
// initial tool list", measured 2026-08-03 against a single server. **That
// finding does not hold for `claude 2.1.221`**: re-measured 2026-08-04, a turn
// whose servers reach `connected` carries their tools inline — 90 `mcp__github__*`
// entries in a 139-tool list, no lookup required.
//
// What the original session actually hit was the race [ClaudeTurnMcpConfig]
// fixes: with 27 servers configured, a connector's status at tool-list time is
// `pending` about as often as `connected`, and a `pending` server contributes
// nothing whether or not the model goes looking. The prompt could not have
// helped — there was no second place to look, only a server that had not
// finished its handshake — and left behind it a paragraph telling every model
// something untrue about its own tools.

/// The argv for one turn: a fresh `claude -p`, or `--resume <id>` to continue a
/// session.
///
/// Pure, and unit-tested, because the failure mode is silent: a mistyped flag
/// looks exactly like a model that wouldn't answer.
///
/// - `--output-format stream-json` with `--verbose` is the only combination that
///   emits events at all; `--include-partial-messages` adds the text deltas that
///   let the answer stream into the bubble instead of landing in one lump.
/// - `--model` is passed even though the environment already names one: the
///   chat's picker is the user's live choice, and a flag beats a file nobody can
///   see.
/// - The prompt goes on **stdin**, not in argv, so a long replayed history can't
///   overflow an argv limit.
/// - `--mcp-config` with `--strict-mcp-config` narrows the turn to the app's own
///   connectors. See [ClaudeTurnMcpConfig] for why, and why [mcpConfigPath] is
///   nullable: a path that doesn't exist aborts the turn outright, so a failed
///   write must drop **both** flags rather than pass a broken one.
List<String> claudeExecArgs({
  required String model,
  String? resumeSessionId,
  String? mcpConfigPath,
}) => [
  '-p',
  '--output-format',
  'stream-json',
  '--include-partial-messages',
  '--verbose',
  '--permission-mode',
  kClaudePermissionMode,
  '--model',
  model,
  if (mcpConfigPath != null) ...[
    '--mcp-config',
    mcpConfigPath,
    '--strict-mcp-config',
  ],
  if (resumeSessionId != null) ...['--resume', resumeSessionId],
];

/// Real implementation: spawns `claude -p`, feeds the prompt on stdin, and turns
/// its JSONL into [ClaudeExecEvent]s.
class ClaudeExecServiceImpl implements ClaudeExecService {
  const ClaudeExecServiceImpl(this._path);

  final String _path;

  @override
  ClaudeExecRun run({
    required String workdir,
    required String prompt,
    required String model,
    required Map<String, String> environment,
    String? resumeSessionId,
    String? mcpConfigPath,
  }) => _ClaudeExecTurn(
    path: _path,
    workdir: workdir,
    prompt: prompt,
    model: model,
    environment: environment,
    resumeSessionId: resumeSessionId,
    mcpConfigPath: mcpConfigPath,
  ).start();
}

class _ClaudeExecTurn {
  _ClaudeExecTurn({
    required this.path,
    required this.workdir,
    required this.prompt,
    required this.model,
    required this.environment,
    required this.resumeSessionId,
    required this.mcpConfigPath,
  });

  final String path;
  final String workdir;
  final String prompt;
  final String model;
  final Map<String, String> environment;
  final String? resumeSessionId;
  final String? mcpConfigPath;

  final _events = StreamController<ClaudeExecEvent>();
  final _done = Completer<void>();
  final _parser = ClaudeStreamParser();

  Process? _process;
  var _killed = false;

  /// The last few stderr lines, to quote back when the process dies before it
  /// says anything useful on stdout.
  final _stderr = <String>[];
  static const _stderrKept = 20;

  /// Whether the turn said anything on stdout — an answer or its own failure.
  /// When it didn't, stderr is the only account of what happened, so the exit
  /// carries it back instead of leaving the chat with "no answer" and no reason.
  var _spoke = false;

  /// Whether the turn has already reported how it ended, so the exit below adds
  /// neither a second verdict nor one that contradicts the first.
  var _failed = false;
  var _completed = false;

  ClaudeExecRun start() {
    Process.start(
      path,
      claudeExecArgs(
        model: model,
        resumeSessionId: resumeSessionId,
        mcpConfigPath: mcpConfigPath,
      ),
      workingDirectory: workdir,
      environment: {
        ...Platform.environment,
        'PATH': HostEnvironment.path(),
        ...environment,
      },
    ).then(_onStarted).catchError(_onStartError);
    return ClaudeExecRun(
      events: _events.stream,
      done: _done.future,
      kill: kill,
    );
  }

  void _onStarted(Process process) {
    if (_killed) {
      process.kill();
      return;
    }
    _process = process;
    process.stdin
      ..write(prompt)
      ..close();

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine);
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onStderr);

    process.exitCode.then(_onExit);
  }

  void _onStartError(Object error) {
    final message = error is ProcessException ? error.message : '$error';
    if (!_events.isClosed) {
      _events.addError(
        ClaudeExecException('Claude Code could not start: $message'),
      );
    }
    _finish();
  }

  void _onStderr(String line) {
    if (line.trim().isEmpty) return;
    _stderr.add(line);
    if (_stderr.length > _stderrKept) _stderr.removeAt(0);
  }

  void _onLine(String line) {
    if (_events.isClosed) return;
    final decoded = _tryDecode(line);
    if (decoded == null) return;
    for (final event in _parser.read(decoded)) {
      _note(event);
      _events.add(event);
    }
  }

  /// Remember what the turn has told us, for the exit path below.
  void _note(ClaudeExecEvent event) {
    switch (event) {
      case ClaudeMessageEvent():
        _spoke = true;
      case ClaudeTurnFailed():
        _spoke = true;
        _failed = true;
      case ClaudeTurnCompleted():
        _completed = true;
      // A step, a plan, a file about to be written, the session id: work in
      // progress, not a word on how the turn ends.
      default:
    }
  }

  /// A turn that dies without a word on stdout — a config Claude won't load, a
  /// crash, a killed process — would otherwise reach the chat as "no answer",
  /// with the reason sitting unread in [_stderr]. Hand that reason over instead.
  void _onExit(int code) {
    if (_killed || _events.isClosed) {
      _finish();
      return;
    }
    if (code == 0 && !_failed && !_completed) {
      _events.add(const ClaudeTurnCompleted());
    } else if (!_spoke && code != 0) {
      final tail = _stderr.join('\n').trim();
      _events.add(
        ClaudeTurnFailed(
          tail.isEmpty ? 'Claude Code exited with code $code.' : tail,
        ),
      );
    }
    _finish();
  }

  void kill() {
    _killed = true;
    _process?.kill();
    _finish();
  }

  void _finish() {
    if (_done.isCompleted) return;
    _done.complete();
    if (!_events.isClosed) _events.close();
  }
}

Map<String, dynamic>? _tryDecode(String line) {
  if (line.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(line);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}
