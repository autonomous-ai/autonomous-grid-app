import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../logging/app_log.dart';
import 'agent_event.dart';
import 'hermes_permission_policy.dart';
import 'host_environment.dart';

/// One thing to show from a running Hermes ACP turn: a tool step for the
/// activity feed, or a chunk of the streamed answer.
sealed class HermesAcpEvent {
  const HermesAcpEvent();
}

/// A shell command or tool call the agent ran — reuses [AgentActivity] so the
/// Chat tab's activity feed is identical across codex and hermes.
class HermesAcpActivity extends HermesAcpEvent {
  const HermesAcpActivity(this.activity);
  final AgentActivity activity;
}

/// A chunk of the assistant's answer, streamed as it's generated.
class HermesAcpMessage extends HermesAcpEvent {
  const HermesAcpMessage(this.text);
  final String text;
}

/// The agent is waiting on the user: it wants to run a command or change a file.
/// The turn is stalled until [HermesAcpSession.answerPermission] is called with
/// the request's id — see [decideHermesPermission].
class HermesAcpPermission extends HermesAcpEvent {
  const HermesAcpPermission(this.request);
  final AgentPermission request;
}

/// The agent edited a file without the user being asked — Full access let it
/// through. Carries the same [AgentPermission] (path, old and new text) an ask
/// would, so the change can be recorded for undo even when nobody approved it.
class HermesAcpEdit extends HermesAcpEvent {
  const HermesAcpEdit(this.request);
  final AgentPermission request;
}

/// The pages a web look-up turned up, parsed from a `web_search` tool result.
/// The chat collects these across the turn and shows them as citations under
/// the answer, so a reply built from the web says where it came from.
class HermesAcpSources extends HermesAcpEvent {
  const HermesAcpSources(this.sources);
  final List<WebSource> sources;
}

/// The agent's to-do plan as it stands now (its `todo` tool state, over ACP's
/// `plan` update). Replaces the previous plan wholesale — Hermes sends the whole
/// list each time — so the chat shows the steps and which one it's on.
class HermesAcpPlan extends HermesAcpEvent {
  const HermesAcpPlan(this.entries);
  final List<AgentPlanEntry> entries;
}

/// A handle to one running prompt turn: its parsed events, a future that
/// completes when the turn ends, and a kill switch for that turn.
class HermesAcpRun {
  const HermesAcpRun({
    required this.events,
    required this.done,
    required this.kill,
  });

  final Stream<HermesAcpEvent> events;
  final Future<void> done;
  final void Function() kill;
}

/// Thrown when a Hermes session can't be established (the binary won't launch,
/// or the handshake never completes).
class HermesAcpException implements Exception {
  const HermesAcpException(this.message, {this.retryable = true});

  final String message;

  /// Whether sending again could plausibly work. False for a machine that isn't
  /// set up (a missing dependency, a broken install): the same send will fail
  /// the same way every time, so telling the user to retry only wastes theirs.
  final bool retryable;

  @override
  String toString() => 'HermesAcpException: $message';
}

/// Opens a Hermes ACP session — Hermes's Agent Client Protocol (newline-
/// delimited JSON-RPC over stdio). Behind an interface so the sender is tested
/// against a fake that replays scripted turns.
///
/// ACP is used instead of `hermes -z` because `-z` prints only the final answer
/// ("no tool previews"), whereas ACP streams `tool_call` / `tool_call_update`
/// and `agent_message_chunk` updates — so the Chat tab can show what the agent
/// is doing, live.
abstract interface class HermesAcpService {
  /// Spawns `hermes acp`, runs the initialize → session/new handshake, and
  /// returns a live [HermesAcpSession]. Throws [HermesAcpException] if the
  /// process won't start or the handshake doesn't complete.
  Future<HermesAcpSession> start({required String workdir});
}

/// A live `hermes acp` process kept across a conversation's turns. `initialize`
/// and `session/new` run once at [HermesAcpService.start]; each [prompt] is a
/// `session/prompt` that carries only the new message, so Hermes holds the
/// conversation context itself instead of the app resending the whole history
/// (and re-spawning the process) every turn.
abstract interface class HermesAcpSession {
  /// Whether the process has exited or been closed — the sender restarts a fresh
  /// session rather than prompting a dead one.
  bool get isClosed;

  /// Hermes's own id for this session, known once the handshake completed. It's
  /// how the app looks the session up afterwards — to read the name Hermes gave
  /// it, see [HermesSessionService].
  String? get sessionId;

  /// How much the agent is allowed to do without being asked. Set by the caller
  /// before each turn from what the user chose in the composer, so switching the
  /// mode takes effect on the very next message rather than the next session.
  set approvalMode(AgentApprovalMode mode);

  /// Runs one user turn. Only one turn is in flight at a time — the caller
  /// awaits [HermesAcpRun.done] before the next.
  HermesAcpRun prompt(String text);

  /// Answer a [HermesAcpPermission] the agent is waiting on: [optionId] is the
  /// choice it offered, or null to cancel it (which the agent reads as no). The
  /// turn resumes — or doesn't — on this call.
  void answerPermission(Object requestId, String? optionId);

  /// Kills the process and releases the session.
  Future<void> close();
}

/// Real implementation: one persistent `hermes acp` process, its stdout routed
/// to the handshake, to the active turn, or to the permission policy (which
/// refuses the dangerous commands and file edits the agent escalates — see
/// [decideHermesPermission]).
class HermesAcpServiceImpl implements HermesAcpService {
  const HermesAcpServiceImpl(this._path, {AppLog log = const NoopAppLog()})
    : _log = log;

  final String _path;

  /// Where every permission decision is written. Defaults to a no-op so a test
  /// needn't wire one, but the app passes the real one — a decision nobody can
  /// read afterwards is how a blocked agent stayed a mystery for a session.
  final AppLog _log;

  @override
  Future<HermesAcpSession> start({required String workdir}) async {
    final session = _HermesAcpSession(_path, workdir, _log);
    await session.open();
    return session;
  }
}

class _HermesAcpSession implements HermesAcpSession {
  _HermesAcpSession(this._path, this._workdir, this._log);

  final String _path;
  final String _workdir;
  final AppLog _log;

  // The handshake occupies ids 0 (initialize) and 1 (session/new); prompt turns
  // take the rest, one id each, so a turn's response is matched by its id.
  static const _initializeId = 0;
  static const _newSessionId = 1;
  int _nextId = 2;

  Process? _process;
  String? _sessionId;
  bool _closed = false;
  final _ready = Completer<void>();

  /// Ask before acting until told otherwise — the safe default if a caller ever
  /// forgets to set it.
  AgentApprovalMode _approvalMode = AgentApprovalMode.ask;

  @override
  set approvalMode(AgentApprovalMode mode) => _approvalMode = mode;

  @override
  bool get isClosed => _closed;

  @override
  String? get sessionId => _sessionId;

  // The turn in flight, or null between turns.
  StreamController<HermesAcpEvent>? _events;
  Completer<void>? _turnDone;
  int? _turnId;
  // Kind/title arrive only on the first tool_call; a later tool_call_update
  // carries just id + status, so remember them to keep the label. Cleared each
  // turn so one turn's tools don't bleed into the next.
  final _tools = <String, AgentActivity>{};

  /// Spawn and run the handshake; completes when the session is ready to prompt.
  Future<void> open() async {
    try {
      _process = await Process.start(
        _path,
        ['acp'],
        workingDirectory: _workdir,
        environment: {...Platform.environment, 'PATH': HostEnvironment.path()},
      );
    } on ProcessException catch (e) {
      throw HermesAcpException('Hermes could not start: ${e.message}');
    }

    _listen();
    _write({
      'jsonrpc': '2.0',
      'id': _initializeId,
      'method': 'initialize',
      'params': {
        'protocolVersion': 1,
        'clientCapabilities': {
          'fs': {'readTextFile': false, 'writeTextFile': false},
        },
      },
    });

    // A dead process before session/new means the handshake failed — surface it
    // instead of hanging the first prompt forever.
    unawaited(
      _process!.exitCode.then((_) {
        _closed = true;
        if (!_ready.isCompleted) {
          // Hermes explains a failed startup on stderr and nowhere else. The
          // chat now shows a humanized line ([friendlyAgentStartupError]), so
          // the raw reason lives here — a durable record to diagnose from, not
          // the wall of jargon the user used to read.
          final said = _stderrTail;
          _log.warn(
            'agent',
            said.isEmpty
                ? 'Hermes exited during startup with no message.'
                : 'Hermes exited during startup: $said',
          );
          _ready.completeError(
            HermesAcpException(
              said.isEmpty
                  ? 'Hermes exited during startup.'
                  : 'Hermes exited during startup: $said',
              retryable: false,
            ),
          );
        }
        _endTurn();
      }),
    );

    return _ready.future;
  }

  @override
  HermesAcpRun prompt(String text) {
    if (_closed || _process == null || _sessionId == null) {
      return HermesAcpRun(
        events: const Stream.empty(),
        done: Future.value(),
        kill: () {},
      );
    }
    final events = StreamController<HermesAcpEvent>();
    final done = Completer<void>();
    _events = events;
    _turnDone = done;
    _turnId = _nextId++;
    _tools.clear();

    _write({
      'jsonrpc': '2.0',
      'id': _turnId,
      'method': 'session/prompt',
      'params': {
        'sessionId': _sessionId,
        'prompt': [
          {'type': 'text', 'text': text},
        ],
      },
    });

    return HermesAcpRun(events: events.stream, done: done.future, kill: close);
  }

  @override
  Future<void> close() async {
    _closed = true;
    _process?.kill();
    _endTurn();
  }

  void _listen() {
    _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
          final decoded = _tryDecode(line);
          if (decoded != null) _handle(decoded);
        });
    // Hermes explains a failed startup on stderr and nowhere else ("ACP
    // dependencies not installed", an import traceback, a bad config). Dropping
    // it left the user with "try again" for faults retrying can never fix, so
    // keep the tail to quote back in [HermesAcpException].
    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
          if (line.trim().isEmpty) return;
          _stderr.add(line);
          if (_stderr.length > _stderrKept) _stderr.removeAt(0);
        });
  }

  /// The last few stderr lines, kept as a ring buffer: enough to explain a
  /// startup failure, bounded so a long-running chatty session can't grow it.
  static const _stderrKept = 20;
  final _stderr = <String>[];

  /// What Hermes said before dying, as a single line — empty when it said
  /// nothing. Python tracebacks put the cause last, so the tail is the useful
  /// part.
  String get _stderrTail {
    final lines = _stderr.where((l) => !_isNoise(l)).toList();
    if (lines.isEmpty) return '';
    return lines.length <= 3
        ? lines.join(' ')
        : lines.sublist(lines.length - 3).join(' ');
  }

  /// Routine `[INFO]`/`[DEBUG]` progress chatter, which would otherwise crowd
  /// out the actual error in a short tail.
  static bool _isNoise(String line) =>
      line.contains('[INFO]') || line.contains('[DEBUG]');

  void _handle(Map<String, dynamic> message) {
    if (message['method'] == 'session/update') {
      _handleUpdate(message['params']?['update']);
      return;
    }
    // A server→client request (method + id): gate permissions, ack the rest.
    if (message['method'] != null && message['id'] != null) {
      _respond(message);
      return;
    }
    switch (message['id']) {
      case _initializeId:
        _write({
          'jsonrpc': '2.0',
          'id': _newSessionId,
          'method': 'session/new',
          'params': {'cwd': _workdir, 'mcpServers': const []},
        });
      case _newSessionId:
        _sessionId = _str(message['result']?['sessionId']);
        if (!_ready.isCompleted) _ready.complete();
      default:
        // A prompt response ends its turn.
        if (message['id'] == _turnId) _endTurn();
    }
  }

  void _handleUpdate(Object? raw) {
    if (raw is! Map) return;
    final events = _events;
    if (events == null || events.isClosed) return;
    switch (raw['sessionUpdate']) {
      case 'tool_call':
        final id = _str(raw['toolCallId']);
        final activity = AgentActivity(
          id: id,
          kind: _activityKind(raw['kind']),
          label: _str(raw['title'], fallback: 'tool'),
          status: AgentActivityStatus.running,
        );
        _tools[id] = activity;
        events.add(HermesAcpActivity(activity));
      case 'tool_call_update':
        final id = _str(raw['toolCallId']);
        final prior = _tools[id];
        final kind = prior?.kind ?? _activityKind(raw['kind']);
        final activity = AgentActivity(
          id: id,
          kind: kind,
          label: prior?.label ?? 'tool',
          status: _status(raw['status']),
        );
        _tools[id] = activity;
        events.add(HermesAcpActivity(activity));
        // A finished web look-up carries its results in the tool content — lift
        // them out as citations to show under the answer.
        if (kind == AgentActivityKind.web) {
          final sources = parseWebSearchSources(
            _toolContentText(raw['content']),
          );
          if (sources.isNotEmpty) events.add(HermesAcpSources(sources));
        }
      case 'plan':
        // The agent's own to-do list (its `todo` tool) — the whole list each
        // time, so it replaces rather than appends.
        events.add(HermesAcpPlan(parseAgentPlan(raw['entries'])));
      case 'agent_message_chunk':
        final content = raw['content'];
        if (content is Map && content['text'] is String) {
          events.add(HermesAcpMessage(content['text'] as String));
        }
    }
  }

  // Server → client requests. Permission prompts go through the policy: reads
  // are allowed, a command or a file change is put to the user (see
  // [decideHermesPermission]), and anything else is refused. Everything that
  // isn't a permission prompt is acknowledged.
  void _respond(Map<String, dynamic> message) {
    final method = message['method'];
    if (method is String && method.contains('permission')) {
      _respondToPermission(message);
      return;
    }
    _write({
      'jsonrpc': '2.0',
      'id': message['id'],
      'result': const <String, Object?>{},
    });
  }

  void _respondToPermission(Map<String, dynamic> message) {
    final id = message['id'] as Object;
    final params = message['params'];
    final toolCall = params is Map ? params['toolCall'] : null;
    final toolKind = _str(
      toolCall is Map ? toolCall['kind'] : null,
      fallback: 'other',
    );
    final options = parsePermissionOptions(
      params is Map ? params['options'] : null,
    );
    final label = _str(
      toolCall is Map ? toolCall['title'] : null,
      fallback: toolKind,
    );

    final decision = decideHermesPermission(
      toolKind: toolKind,
      options: options,
      mode: _approvalMode,
    );
    // Every decision, every time — allowed, refused or put to the user. An
    // agent that quietly can't work looks exactly like one that won't, and
    // without this line there is nothing to tell the two apart afterwards.
    _log.info(
      'agent',
      'acp permission $toolKind "$label" under ${_approvalMode.name} '
          '→ ${_decisionName(decision)}',
    );
    switch (decision) {
      case HermesAllow(:final optionId):
        answerPermission(id, optionId);
        // Full access approved an edit without asking — still surface it so the
        // change can be recorded for undo. Reads are nothing to undo.
        if (toolKind == 'edit') {
          final request = parseAgentPermission(id: id, params: params);
          final events = _events;
          if (request != null && events != null && !events.isClosed) {
            events.add(HermesAcpEdit(request));
          }
        }
      case HermesRefuse(:final optionId):
        answerPermission(id, optionId);
        _blocked(id, label);
      case HermesAskUser():
        final events = _events;
        final request = parseAgentPermission(id: id, params: params);
        // Nobody to ask (the turn already ended), or a message carrying no tool
        // call at all: refuse it. Never approve what nobody saw. Logged with the
        // raw params, because this is the branch we can't reason about later
        // from a summary — the message itself is the evidence.
        if (events == null || events.isClosed || request == null) {
          _log.warn(
            'agent',
            'acp permission refused unasked (${request == null ? 'no tool call '
                      'in the message' : 'no turn listening'}): $params',
          );
          answerPermission(id, refuseOption(options));
          _blocked(id, label);
          return;
        }
        events.add(HermesAcpPermission(request));
    }
  }

  /// What went in the log for [decision] — the outcome, not the class name.
  String _decisionName(HermesPermissionDecision decision) => switch (decision) {
    HermesAllow() => 'allowed',
    HermesRefuse() => 'refused',
    HermesAskUser() => 'asking the user',
  };

  @override
  void answerPermission(Object requestId, String? optionId) {
    // What actually went back to the agent, including the user's own answer —
    // the one line that survives the app closing. A cancel is a no: Hermes has
    // no "reject" option to send when it offered none.
    _log.debug(
      'agent',
      'acp permission #$requestId answered ${optionId ?? 'cancelled (no)'}',
    );
    _write({
      'jsonrpc': '2.0',
      'id': requestId,
      'result': {
        'outcome': optionId != null
            ? {'outcome': 'selected', 'optionId': optionId}
            : {'outcome': 'cancelled'},
      },
    });
  }

  /// A refused action isn't silent: show it in the activity feed, so the user
  /// sees the agent tried something and didn't get to do it — not just an answer
  /// that quietly couldn't do what they asked.
  void _blocked(Object requestId, String label) {
    _events?.add(
      HermesAcpActivity(
        AgentActivity(
          id: 'blocked-$requestId',
          kind: AgentActivityKind.command,
          label: 'Blocked: $label',
          status: AgentActivityStatus.failed,
        ),
      ),
    );
  }

  /// Close the active turn's stream and complete its future. Safe to call more
  /// than once (a prompt response, then process exit).
  void _endTurn() {
    _events?.close();
    _events = null;
    _turnId = null;
    final done = _turnDone;
    _turnDone = null;
    if (done != null && !done.isCompleted) done.complete();
  }

  // Flush after each line: hermes reads newline-delimited JSON-RPC from stdin,
  // and an unflushed buffer would leave it waiting while we wait for its output
  // — a deadlock. Writes are response-driven (never concurrent), so
  // fire-and-forget flushes don't overlap.
  void _write(Map<String, Object?> message) {
    final stdin = _process?.stdin;
    if (stdin == null) return;
    stdin.write('${jsonEncode(message)}\n');
    stdin.flush().ignore();
  }
}

Map<String, dynamic>? _tryDecode(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return null;
  try {
    final decoded = jsonDecode(trimmed);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}

AgentActivityStatus _status(Object? raw) => switch (raw) {
  'failed' => AgentActivityStatus.failed,
  'in_progress' || 'pending' => AgentActivityStatus.running,
  _ => AgentActivityStatus.done,
};

/// Maps an ACP tool kind to a feed [AgentActivityKind]: `execute` is a shell
/// command, `fetch` is a web look-up (search / open a page), everything else a
/// generic tool.
AgentActivityKind _activityKind(Object? kind) => switch (kind) {
  'execute' => AgentActivityKind.command,
  'fetch' => AgentActivityKind.web,
  _ => AgentActivityKind.tool,
};

/// Flattens an ACP tool `content` array to its plain text — each block is
/// `{type: content, content: {type: text, text: …}}`. Used to read a finished
/// web search's results out of its content.
String _toolContentText(Object? content) {
  if (content is! List) return '';
  final buffer = StringBuffer();
  for (final block in content) {
    if (block is Map && block['content'] is Map) {
      final inner = block['content'] as Map;
      if (inner['text'] is String) buffer.writeln(inner['text'] as String);
    }
  }
  return buffer.toString();
}

String _str(Object? raw, {String fallback = ''}) =>
    raw is String ? raw : fallback;
