import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'agent_event.dart';
import 'host_environment.dart';

/// One thing to show from a running Pi turn — the same shapes the Chat tab
/// already renders for Hermes and Codex ([AgentActivity], [AgentPlanEntry], a
/// chunk of the answer), so every agent feeds the one activity/plan/answer feed.
///
/// Pi speaks its own JSON-lines stream over `pi --mode json`, not ACP, so it
/// gets its own thin envelope — but the payloads are the shared, agent-neutral
/// ones, so nothing downstream has to know which agent produced them.
sealed class PiExecEvent {
  const PiExecEvent();
}

/// Pi's id for the session, seen once on the first line (`{"type":"session"}`).
/// The sender keeps it so the next turn can `pi --session <id>` instead of
/// starting the conversation over.
class PiSessionStarted extends PiExecEvent {
  const PiSessionStarted(this.sessionId);
  final String sessionId;
}

/// A shell command, web look-up or tool call Pi ran while answering.
class PiActivityEvent extends PiExecEvent {
  const PiActivityEvent(this.activity);
  final AgentActivity activity;
}

/// The answer so far — the full assembled text, not a delta, so the sender
/// replaces rather than appends (Pi streams deltas; this joins them).
class PiMessageEvent extends PiExecEvent {
  const PiMessageEvent(this.text);
  final String text;
}

/// Pi's to-do list as it stands now, replacing the previous one wholesale.
class PiPlanEvent extends PiExecEvent {
  const PiPlanEvent(this.entries);
  final List<AgentPlanEntry> entries;
}

/// One file Pi created this turn: its (absolute) path. Only a freshly *written*
/// file is recorded — the chat can offer to open what the agent just made —
/// since an edit has no honest before/after to show (mirrors Codex).
class PiFileChangeEvent extends PiExecEvent {
  const PiFileChangeEvent(this.paths);
  final List<String> paths;
}

/// The turn failed for good — Pi's assistant message ended with `stopReason:
/// error`, or the process died. Carries Pi's own last words, humanized by the
/// sender.
class PiTurnFailed extends PiExecEvent {
  const PiTurnFailed(this.message);
  final String message;
}

/// Pi ended the exchange by itself (`agent_end`) — it was done, not cut off.
/// The chat needs the difference for its stall check (see [agentTurnStalled]).
class PiTurnCompleted extends PiExecEvent {
  const PiTurnCompleted();
}

/// Thrown when a Pi turn can't even start (the binary won't launch).
class PiExecException implements Exception {
  const PiExecException(this.message, {this.retryable = true});

  final String message;

  /// Whether sending again could plausibly work. False for a machine that isn't
  /// set up: the same send fails the same way, so a retry only wastes the user's.
  final bool retryable;

  @override
  String toString() => 'PiExecException: $message';
}

/// A single running Pi turn: its parsed events, a future that completes when the
/// process exits, and a kill switch. Each turn is its own `pi --mode json`
/// process that runs once and exits; continuity comes from resuming the session,
/// not keeping the process alive.
class PiExecRun {
  const PiExecRun({
    required this.events,
    required this.done,
    required this.kill,
  });

  final Stream<PiExecEvent> events;
  final Future<void> done;
  final void Function() kill;
}

/// Drives Pi as a chat agent over `pi --mode json`. Behind an interface so the
/// sender is tested against a fake that replays scripted turns.
abstract interface class PiExecService {
  /// Run one turn. [resumeSessionId] continues an earlier conversation; null
  /// starts a fresh one. [workdir] is the folder the turn opens in.
  ///
  /// [environment] carries the run's own Pi config directory
  /// (`PI_CODING_AGENT_DIR`) and the grid key it names — so a turn answers on
  /// the app's grid without the user's own `~/.pi/agent` being rewritten (see
  /// `piGridEnvironment`). Throws [PiExecException] if the process won't start.
  PiExecRun run({
    required String workdir,
    required String prompt,
    required String model,
    required Map<String, String> environment,
    String? resumeSessionId,
  });
}

/// How Pi is allowed to touch this computer: `--approve` trusts the project for
/// the run, so its `write`/`edit`/`bash` tools act without a prompt.
///
/// TODO(BE): like Codex's `danger-full-access`, this is the widest grant — Pi
/// runs commands and writes files on this machine with nobody asked first.
/// `pi --mode json` is non-interactive and has no per-action approval channel
/// (the thing Hermes gets over ACP), so there is no card and no stopping it
/// mid-command. Named here rather than buried in an argv string.
const String kPiApproveFlag = '--approve';

/// The argv for one Pi turn (flags only — the prompt is appended positionally
/// by the caller, and the grid provider rides in [environment]).
///
/// `--mode json` streams every session event as JSON lines on stdout;
/// `--model grid/<model>` selects the app's grid provider (defined in the run's
/// own `models.json`); `--session <id>` continues an earlier conversation on the
/// same flags — unlike Codex, Pi's resume takes no different subcommand.
///
/// Pure, and unit-tested, because the failure mode is silent: a mistyped flag
/// looks exactly like a model that wouldn't answer.
List<String> piExecArgs({
  required String model,
  String? resumeSessionId,
}) => [
  '--mode',
  'json',
  kPiApproveFlag,
  '--model',
  'grid/$model',
  if (resumeSessionId != null) ...['--session', resumeSessionId],
];

/// Real implementation: spawns `pi --mode json … <prompt>` and turns its JSON
/// session events into [PiExecEvent]s.
class PiExecServiceImpl implements PiExecService {
  const PiExecServiceImpl(this._path);

  final String _path;

  @override
  PiExecRun run({
    required String workdir,
    required String prompt,
    required String model,
    required Map<String, String> environment,
    String? resumeSessionId,
  }) => _PiExecTurn(
    path: _path,
    workdir: workdir,
    prompt: prompt,
    model: model,
    environment: environment,
    resumeSessionId: resumeSessionId,
  ).start();
}

class _PiExecTurn {
  _PiExecTurn({
    required String path,
    required String workdir,
    required String prompt,
    required String model,
    required Map<String, String> environment,
    required String? resumeSessionId,
  }) : _path = path,
       _workdir = workdir,
       _prompt = prompt,
       _model = model,
       _environment = environment,
       _resumeSessionId = resumeSessionId;

  final String _path;
  final String _workdir;
  final String _prompt;
  final String _model;
  final Map<String, String> _environment;
  final String? _resumeSessionId;

  final _events = StreamController<PiExecEvent>();
  final _done = Completer<void>();
  final _state = PiTurnState();
  Process? _process;
  var _killed = false;

  final _stderr = <String>[];
  static const _stderrKept = 20;

  /// Whether the turn said anything on stdout — an answer or its own failure.
  var _spoke = false;

  /// Whether the turn has already reported how it ended, so the exit below adds
  /// neither a second verdict nor one that contradicts the first.
  var _failed = false;
  var _completed = false;

  PiExecRun start() {
    Process.start(
      _path,
      [...piExecArgs(model: _model, resumeSessionId: _resumeSessionId), _prompt],
      workingDirectory: _workdir,
      environment: {
        ...Platform.environment,
        'PATH': HostEnvironment.path(),
        ..._environment,
      },
    ).then(_onStarted).catchError(_onStartError);
    return PiExecRun(events: _events.stream, done: _done.future, kill: kill);
  }

  void _onStarted(Process process) {
    if (_killed) {
      process.kill();
      return;
    }
    _process = process;
    // Pi takes the prompt as an argument; nothing is written to stdin.
    process.stdin.close();

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
      _events.addError(PiExecException('Pi could not start: $message'));
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
    final event = parsePiEvent(decoded, _state);
    if (event == null) return;
    _note(event);
    _events.add(event);
  }

  /// Remember what the turn has told us, for the exit path below.
  void _note(PiExecEvent event) {
    switch (event) {
      case PiMessageEvent():
        _spoke = true;
      case PiTurnFailed():
        _spoke = true;
        _failed = true;
      case PiTurnCompleted():
        _completed = true;
      // A step, a plan, a written file, the session id: work in progress, not a
      // word on how the turn ends.
      default:
    }
  }

  /// A turn that dies without a word on stdout — a config Pi won't load, a
  /// crash, a killed process — reaches the chat as "no answer", with the reason
  /// sitting unread in [_stderr]. Hand that reason over instead. A clean exit is
  /// also worth saying out loud ([PiTurnCompleted]) in case `agent_end` never
  /// arrived.
  void _onExit(int code) {
    if (_killed || _events.isClosed) {
      _finish();
      return;
    }
    if (code == 0 && !_failed && !_completed) {
      _events.add(const PiTurnCompleted());
    } else if (!_spoke && code != 0) {
      final tail = _stderr.join('\n').trim();
      _events.add(
        PiTurnFailed(tail.isEmpty ? 'Pi exited with code $code.' : tail),
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

/// The mutable state one Pi turn threads through [parsePiEvent] — the answer
/// assembled from streamed deltas, and the running tool calls by their id.
///
/// A turn holds one or more assistant messages (each may end with tool calls,
/// then continue after the results). Each is kept separately and the answer is
/// their non-empty texts joined, so an intermediate message's prose doesn't get
/// lost and the final one isn't dropped.
class PiTurnState {
  final List<String> _messages = [];

  /// Display name per tool-call id, so a `tool_execution_end` can name the row
  /// its `tool_execution_start` opened.
  final Map<String, String> toolNames = {};

  /// The path a `write`/`edit` opened with, kept so its completion can be
  /// recorded as a written file.
  final Map<String, String> toolPaths = {};

  /// Open a new assistant message slot.
  void openMessage() => _messages.add('');

  /// Append a streamed text delta to the current assistant message.
  void appendText(String delta) {
    if (_messages.isEmpty) _messages.add('');
    _messages[_messages.length - 1] += delta;
  }

  /// Replace the current assistant message with its authoritative final text.
  void finishMessage(String text) {
    if (_messages.isEmpty) {
      _messages.add(text);
      return;
    }
    _messages[_messages.length - 1] = text;
  }

  /// The answer so far — every non-empty assistant message joined.
  String get answer =>
      _messages.where((m) => m.trim().isNotEmpty).join('\n\n');
}

/// Pi's built-in tools are lowercase; map them onto the vocabulary the chat's
/// activity feed already renders (mirrors the harness's `piToolName`).
const Map<String, String> _piToolNames = {
  'read': 'Read',
  'write': 'Write',
  'edit': 'Edit',
  'bash': 'Bash',
  'grep': 'Grep',
  'find': 'Glob',
  'ls': 'LS',
  'list': 'LS',
  'webfetch': 'WebFetch',
  'websearch': 'WebSearch',
  'todowrite': 'TodoWrite',
  'todoread': 'TodoRead',
  'task': 'Task',
};

String _piToolName(String name) {
  final key = name.toLowerCase();
  if (_piToolNames[key] != null) return _piToolNames[key]!;
  return name.isEmpty ? 'tool' : '${name[0].toUpperCase()}${name.substring(1)}';
}

/// Turns one decoded `pi --mode json` line into a [PiExecEvent], updating
/// [state] as deltas and tool calls arrive. Returns null for lines that carry
/// nothing to show (turn boundaries, thinking, token counts, unknown types) so
/// the parser stays tolerant of a schema that shifts between Pi builds.
///
/// The event vocabulary (Pi 0.84, from `docs/json.md`): a first `session` line;
/// `agent_start` / `agent_end` around the whole exchange; `turn_start` /
/// `turn_end` around each model round; `message_start` / `message_update`
/// (delta-only `assistantMessageEvent`) / `message_end` (the authoritative
/// message); and `tool_execution_start` / `tool_execution_end`. Only `agent_end`
/// ends the exchange, and a `message_end` whose assistant message stopped on an
/// error is the failure.
PiExecEvent? parsePiEvent(Map<String, dynamic> event, PiTurnState state) {
  switch (event['type']) {
    case 'session':
      final id = event['id'];
      return id is String && id.isNotEmpty ? PiSessionStarted(id) : null;
    case 'message_start':
      if (_role(event['message']) == 'assistant') state.openMessage();
      return null;
    case 'message_update':
      return _parseMessageUpdate(event['assistantMessageEvent'], state);
    case 'message_end':
      return _parseMessageEnd(event['message'], state);
    case 'tool_execution_start':
      return _parseToolStart(event, state);
    case 'tool_execution_end':
      return _parseToolEnd(event, state);
    case 'agent_end':
      return const PiTurnCompleted();
    default:
      // turn_start/turn_end (per-round, not the exchange), agent_start,
      // compaction_*, queue_update: nothing to surface.
      return null;
  }
}

/// A streamed assistant delta. Only text builds the answer; thinking is the
/// model's own working-out, and tool-call argument deltas are covered by the
/// authoritative `tool_execution_*` events, so both are dropped here.
PiExecEvent? _parseMessageUpdate(Object? raw, PiTurnState state) {
  final event = raw is Map ? raw : null;
  if (event == null || event['type'] != 'text_delta') return null;
  final delta = event['delta'];
  if (delta is! String || delta.isEmpty) return null;
  state.appendText(delta);
  return PiMessageEvent(state.answer);
}

/// The authoritative end of one assistant message: its final text (covering a
/// build that streams no deltas), or its failure when it stopped on an error.
PiExecEvent? _parseMessageEnd(Object? raw, PiTurnState state) {
  final message = raw is Map ? raw : null;
  if (message == null || message['role'] != 'assistant') return null;
  if (message['stopReason'] == 'error') {
    final reason = message['errorMessage'];
    return PiTurnFailed(reason is String && reason.isNotEmpty ? reason : '');
  }
  final text = _contentText(message['content']);
  state.finishMessage(text);
  return text.trim().isEmpty ? null : PiMessageEvent(state.answer);
}

PiExecEvent? _parseToolStart(Map<String, dynamic> event, PiTurnState state) {
  final id = '${event['toolCallId'] ?? ''}';
  if (id.isEmpty) return null;
  final rawName = '${event['toolName'] ?? ''}';
  final args = event['args'] is Map
      ? (event['args'] as Map).cast<String, dynamic>()
      : const <String, dynamic>{};
  final tool = _piToolName(rawName);
  state.toolNames[id] = tool;

  // Pi surfaces its to-do list as a `todowrite` tool call carrying the plan.
  if (rawName.toLowerCase() == 'todowrite') {
    return PiPlanEvent(_parsePlan(args['todos']));
  }
  // Remember what a write/edit is touching, so its completion can be recorded.
  final path = _pathArg(args);
  if (path != null) state.toolPaths[id] = path;

  return PiActivityEvent(
    AgentActivity(
      id: id,
      kind: _kindFor(rawName),
      label: _startLabel(rawName, args, tool),
      status: AgentActivityStatus.running,
    ),
  );
}

PiExecEvent? _parseToolEnd(Map<String, dynamic> event, PiTurnState state) {
  final id = '${event['toolCallId'] ?? ''}';
  if (id.isEmpty) return null;
  final rawName = '${event['toolName'] ?? ''}';
  final tool = state.toolNames.remove(id) ?? _piToolName(rawName);
  final isError = event['isError'] == true;
  final path = state.toolPaths.remove(id);

  // A `todowrite` completion carries no new plan — the start already emitted it.
  if (rawName.toLowerCase() == 'todowrite') return null;

  // A file freshly written (not an edit) is offered to the chat to open. Only
  // `write` creates a file with an honest whole-file "after"; an `edit` reports
  // no before, so — like Codex — it isn't recorded.
  if (rawName.toLowerCase() == 'write' && !isError && path != null) {
    return PiFileChangeEvent([path]);
  }

  return PiActivityEvent(
    AgentActivity(
      id: id,
      kind: _kindFor(rawName),
      label: tool,
      status: isError ? AgentActivityStatus.failed : AgentActivityStatus.done,
    ),
  );
}

/// Pi's tool → the activity kind that picks its icon.
AgentActivityKind _kindFor(String rawName) => switch (rawName.toLowerCase()) {
  'bash' => AgentActivityKind.command,
  'websearch' || 'webfetch' => AgentActivityKind.web,
  _ => AgentActivityKind.tool,
};

/// The label a running step shows: the command for a shell call, the query for a
/// web look-up, else the tool's own name.
String _startLabel(String rawName, Map<String, dynamic> args, String tool) =>
    switch (rawName.toLowerCase()) {
      'bash' => '${args['command'] ?? args['cmd'] ?? tool}',
      'websearch' => '${args['query'] ?? tool}',
      'webfetch' => '${args['url'] ?? tool}',
      _ => tool,
    };

/// The file path a `write`/`edit` names, under whichever key Pi uses. Best
/// effort — a key we don't know just leaves the file unrecorded, never wrong.
/// TODO(verify): confirm Pi's write-tool arg key against a real session.
String? _pathArg(Map<String, dynamic> args) {
  for (final key in const ['path', 'file_path', 'filePath', 'filename']) {
    final value = args[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}

/// The text of an assistant message's `content` — its `text` parts joined, with
/// thinking and tool calls left out.
String _contentText(Object? content) {
  if (content is String) return content;
  if (content is! List) return '';
  final buffer = StringBuffer();
  for (final part in content) {
    if (part is Map && part['type'] == 'text' && part['text'] is String) {
      buffer.write(part['text']);
    }
  }
  return buffer.toString();
}

/// Pi's `todowrite` args carry `todos: [{content|text, status}]`; map them to
/// the shared plan model. A blank step is dropped; an unknown status reads as
/// pending, and `in_progress` as the active step.
List<AgentPlanEntry> _parsePlan(Object? raw) {
  if (raw is! List) return const [];
  final entries = <AgentPlanEntry>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final content = cleanPlanContent(entry['content'] ?? entry['text']);
    if (content == null) continue;
    entries.add(
      AgentPlanEntry(content: content, status: _planStatus(entry['status'])),
    );
  }
  return List.unmodifiable(entries);
}

AgentPlanStatus _planStatus(Object? raw) => switch (raw) {
  'in_progress' || 'active' => AgentPlanStatus.active,
  'completed' || 'done' => AgentPlanStatus.done,
  _ => AgentPlanStatus.pending,
};

String? _role(Object? message) =>
    message is Map && message['role'] is String
    ? message['role'] as String
    : null;
