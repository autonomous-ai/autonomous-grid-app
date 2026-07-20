import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'agent_event.dart';
import 'host_environment.dart';

/// One thing to show from a running Codex turn — the same shapes the Chat tab
/// already renders for Hermes ([AgentActivity], [WebSource], [AgentPlanEntry], a
/// chunk of the answer), so both agents feed the one activity/plan/sources feed.
///
/// Codex speaks its own JSONL over `codex exec --json`, not ACP, so it gets its
/// own thin envelope — but the payloads are the shared, agent-neutral ones, so
/// nothing downstream has to know which agent produced them.
sealed class CodexExecEvent {
  const CodexExecEvent();
}

/// Codex's id for the conversation, seen once at the top of the first turn. The
/// sender keeps it so the next turn can `codex exec resume <id>` instead of
/// starting the conversation over.
class CodexThreadStarted extends CodexExecEvent {
  const CodexThreadStarted(this.threadId);
  final String threadId;
}

/// A shell command, web look-up or tool call Codex ran while answering.
class CodexActivityEvent extends CodexExecEvent {
  const CodexActivityEvent(this.activity);
  final AgentActivity activity;
}

/// The answer so far — the full assembled text, not a delta, so the sender
/// replaces rather than appends (Codex reports each message whole).
class CodexMessageEvent extends CodexExecEvent {
  const CodexMessageEvent(this.text);
  final String text;
}

/// Codex's to-do list as it stands now, replacing the previous one wholesale.
class CodexPlanEvent extends CodexExecEvent {
  const CodexPlanEvent(this.entries);
  final List<AgentPlanEntry> entries;
}

/// The turn failed for good — the model stream broke, auth was rejected, the
/// grid didn't answer. Carries Codex's own last words, humanized by the sender.
class CodexTurnFailed extends CodexExecEvent {
  const CodexTurnFailed(this.message);
  final String message;
}

/// Thrown when a Codex turn can't even start (the binary won't launch).
class CodexExecException implements Exception {
  const CodexExecException(this.message, {this.retryable = true});

  final String message;

  /// Whether sending again could plausibly work. False for a machine that isn't
  /// set up: the same send fails the same way, so a retry only wastes the user's.
  final bool retryable;

  @override
  String toString() => 'CodexExecException: $message';
}

/// A single running Codex turn: its parsed events, a future that completes when
/// the process exits, and a kill switch. Unlike Hermes's persistent ACP session,
/// each Codex turn is its own `codex exec` process that runs once and exits;
/// continuity comes from resuming the thread, not keeping the process alive.
class CodexExecRun {
  const CodexExecRun({
    required this.events,
    required this.done,
    required this.kill,
  });

  final Stream<CodexExecEvent> events;
  final Future<void> done;
  final void Function() kill;
}

/// Drives Codex as a chat agent over `codex exec --json`. Behind an interface so
/// the sender is tested against a fake that replays scripted turns.
abstract interface class CodexExecService {
  /// Run one turn. [resumeThreadId] continues an earlier conversation; null
  /// starts a fresh one. [workdir] is the agent's read-only working root; the
  /// model and grid endpoint come from `~/.codex/config.toml`, which the sender
  /// points at the grid before the turn. Throws [CodexExecException] if the
  /// process won't start.
  CodexExecRun run({
    required String workdir,
    required String prompt,
    String? resumeThreadId,
  });
}

/// Real implementation: spawns `codex exec --json` read-only, feeds the prompt on
/// stdin (so a long replayed history can't overflow an argv limit), and turns its
/// JSONL thread events into [CodexExecEvent]s.
class CodexExecServiceImpl implements CodexExecService {
  const CodexExecServiceImpl(this._path);

  final String _path;

  @override
  CodexExecRun run({
    required String workdir,
    required String prompt,
    String? resumeThreadId,
  }) {
    final turn = _CodexExecTurn(_path, workdir, prompt, resumeThreadId);
    return turn.start();
  }
}

class _CodexExecTurn {
  _CodexExecTurn(this._path, this._workdir, this._prompt, this._resumeThreadId);

  final String _path;
  final String _workdir;
  final String _prompt;
  final String? _resumeThreadId;

  final _events = StreamController<CodexExecEvent>();
  final _done = Completer<void>();
  Process? _process;
  var _killed = false;

  /// Assembled answer so far, keyed by Codex's item id — a turn can hold more
  /// than one message, and each arrives whole, so we keep the latest of each and
  /// join them rather than concatenating deltas.
  final _messages = <String, String>{};

  /// The last few stderr lines, to quote back when the process dies before it
  /// says anything useful on stdout.
  final _stderr = <String>[];
  static const _stderrKept = 20;

  CodexExecRun start() {
    Process.start(
      _path,
      _args(),
      workingDirectory: _workdir,
      environment: {...Platform.environment, 'PATH': HostEnvironment.path()},
    ).then(_onStarted).catchError(_onStartError);
    return CodexExecRun(events: _events.stream, done: _done.future, kill: kill);
  }

  List<String> _args() => [
    'exec',
    if (_resumeThreadId case final id?) ...['resume', id],
    '--json',
    '--skip-git-repo-check',
    '--sandbox',
    'read-only',
    '-C',
    _workdir,
  ];

  void _onStarted(Process process) {
    if (_killed) {
      process.kill();
      return;
    }
    _process = process;
    process.stdin
      ..write(_prompt)
      ..close();

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine);
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onStderr);

    process.exitCode.then((_) => _finish());
  }

  void _onStartError(Object error) {
    final message = error is ProcessException ? error.message : '$error';
    if (!_events.isClosed) {
      _events.addError(CodexExecException('Codex could not start: $message'));
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
    final event = parseCodexEvent(decoded, _messages);
    if (event != null) _events.add(event);
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

/// Turns one decoded `codex exec --json` line into a [CodexExecEvent], updating
/// [messages] (the answer-by-item-id accumulator) as agent messages arrive.
/// Returns null for lines that carry nothing to show — reasoning, token counts,
/// transient reconnect notices, unknown types — so the parser stays tolerant of
/// a schema that shifts between Codex builds.
///
/// The event vocabulary (Codex 0.141): a top-level `type` of `thread.started`,
/// `turn.started` / `turn.completed` / `turn.failed`, `item.started` /
/// `item.updated` / `item.completed` (each wrapping an `item` with its own
/// `type`), and a transient top-level `error`. Only `turn.failed` is fatal — a
/// bare `error` is a retry notice Codex recovers from on its own.
CodexExecEvent? parseCodexEvent(
  Map<String, dynamic> event,
  Map<String, String> messages,
) {
  switch (event['type']) {
    case 'thread.started':
      final id = event['thread_id'];
      return id is String && id.isNotEmpty ? CodexThreadStarted(id) : null;
    case 'turn.failed':
      final message = event['error'];
      return CodexTurnFailed(
        message is Map ? '${message['message'] ?? ''}' : '',
      );
    case 'item.started':
    case 'item.updated':
    case 'item.completed':
      final item = event['item'];
      return item is Map ? _parseItem(item.cast<String, dynamic>(), messages) : null;
    default:
      // turn.started, turn.completed, token counts, transient errors: nothing to
      // surface. A bare `error` here is a reconnect notice, not a turn failure.
      return null;
  }
}

CodexExecEvent? _parseItem(
  Map<String, dynamic> item,
  Map<String, String> messages,
) {
  final id = '${item['id'] ?? ''}';
  switch (item['type']) {
    case 'agent_message':
      final text = '${item['text'] ?? ''}';
      if (text.isEmpty) return null;
      messages[id] = text;
      return CodexMessageEvent(
        messages.values.where((m) => m.isNotEmpty).join('\n\n'),
      );
    case 'command_execution':
      return CodexActivityEvent(
        AgentActivity(
          id: id,
          kind: AgentActivityKind.command,
          label: '${item['command'] ?? 'command'}',
          status: _statusOf(item['status']),
        ),
      );
    case 'web_search':
      return CodexActivityEvent(
        AgentActivity(
          id: id,
          kind: AgentActivityKind.web,
          label: '${item['query'] ?? 'Web search'}',
          status: _statusOf(item['status']),
        ),
      );
    case 'mcp_tool_call':
      final tool = item['tool'] ?? item['server'] ?? 'tool';
      return CodexActivityEvent(
        AgentActivity(
          id: id,
          kind: AgentActivityKind.tool,
          label: '$tool',
          status: _statusOf(item['status']),
        ),
      );
    case 'todo_list':
      return CodexPlanEvent(_parseTodoList(item['items']));
    default:
      // reasoning, file_change (never in read-only), error warnings: not shown.
      return null;
  }
}

/// Codex reports an item's lifecycle as `in_progress` / `completed` / `failed`;
/// anything else reads as still running, never as done.
AgentActivityStatus _statusOf(Object? raw) => switch (raw) {
  'completed' => AgentActivityStatus.done,
  'failed' => AgentActivityStatus.failed,
  _ => AgentActivityStatus.running,
};

/// Codex's `todo_list` item carries `items: [{text, completed}]`; map it to the
/// shared plan model. Codex has no "active" step, so a step is either done or
/// pending — a blank one is dropped.
List<AgentPlanEntry> _parseTodoList(Object? raw) {
  if (raw is! List) return const [];
  final entries = <AgentPlanEntry>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final text = '${entry['text'] ?? ''}'.trim();
    if (text.isEmpty) continue;
    entries.add(
      AgentPlanEntry(
        content: text,
        status: entry['completed'] == true
            ? AgentPlanStatus.done
            : AgentPlanStatus.pending,
      ),
    );
  }
  return List.unmodifiable(entries);
}
