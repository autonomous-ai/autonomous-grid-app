import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  const HermesAcpException(this.message);
  final String message;

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

  /// Runs one user turn. Only one turn is in flight at a time — the caller
  /// awaits [HermesAcpRun.done] before the next.
  HermesAcpRun prompt(String text);

  /// Kills the process and releases the session.
  Future<void> close();
}

/// Real implementation: one persistent `hermes acp` process, its stdout routed
/// to the handshake, to the active turn, or to the permission policy (which
/// refuses the dangerous commands and file edits the agent escalates — see
/// [decideHermesPermission]).
class HermesAcpServiceImpl implements HermesAcpService {
  const HermesAcpServiceImpl(this._path);

  final String _path;

  @override
  Future<HermesAcpSession> start({required String workdir}) async {
    final session = _HermesAcpSession(_path, workdir);
    await session.open();
    return session;
  }
}

class _HermesAcpSession implements HermesAcpSession {
  _HermesAcpSession(this._path, this._workdir);

  final String _path;
  final String _workdir;

  // The handshake occupies ids 0 (initialize) and 1 (session/new); prompt turns
  // take the rest, one id each, so a turn's response is matched by its id.
  static const _initializeId = 0;
  static const _newSessionId = 1;
  int _nextId = 2;

  Process? _process;
  String? _sessionId;
  bool _closed = false;
  final _ready = Completer<void>();

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
          _ready.completeError(
            const HermesAcpException('Hermes exited during startup.'),
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
    _process!.stderr.transform(utf8.decoder).drain<void>();
  }

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
          kind: raw['kind'] == 'execute'
              ? AgentActivityKind.command
              : AgentActivityKind.tool,
          label: _str(raw['title'], fallback: 'tool'),
          status: AgentActivityStatus.running,
        );
        _tools[id] = activity;
        events.add(HermesAcpActivity(activity));
      case 'tool_call_update':
        final id = _str(raw['toolCallId']);
        final prior = _tools[id];
        final activity = AgentActivity(
          id: id,
          kind: prior?.kind ?? AgentActivityKind.tool,
          label: prior?.label ?? 'tool',
          status: _status(raw['status']),
        );
        _tools[id] = activity;
        events.add(HermesAcpActivity(activity));
      case 'agent_message_chunk':
        final content = raw['content'];
        if (content is Map && content['text'] is String) {
          events.add(HermesAcpMessage(content['text'] as String));
        }
    }
  }

  // Server → client requests. Permission prompts go through the policy — the
  // dangerous commands and file edits the agent escalates are refused (see
  // [decideHermesPermission]). Everything else is acknowledged.
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
    final params = message['params'];
    final toolCall = params is Map ? params['toolCall'] : null;
    final toolKind = _str(
      toolCall is Map ? toolCall['kind'] : null,
      fallback: 'other',
    );
    final optionId = decideHermesPermission(
      toolKind: toolKind,
      options: _parsePermissionOptions(
        params is Map ? params['options'] : null,
      ),
    );

    final outcome = optionId != null
        ? {'outcome': 'selected', 'optionId': optionId}
        : {'outcome': 'cancelled'};
    _write({
      'jsonrpc': '2.0',
      'id': message['id'],
      'result': {'outcome': outcome},
    });

    // A refused action isn't silent: show it in the activity feed, so the user
    // sees the agent tried something and was blocked — not just an answer that
    // quietly couldn't do what they asked.
    if (!safeToolKinds.contains(toolKind)) {
      _events?.add(
        HermesAcpActivity(
          AgentActivity(
            id: 'blocked-${message['id']}',
            kind: AgentActivityKind.command,
            label:
                'Blocked: ${_str(toolCall is Map ? toolCall['title'] : null, fallback: toolKind)}',
            status: AgentActivityStatus.failed,
          ),
        ),
      );
    }
  }

  List<HermesPermissionOption> _parsePermissionOptions(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final option in raw)
        if (option is Map)
          (optionId: _str(option['optionId']), kind: _str(option['kind'])),
    ];
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

String _str(Object? raw, {String fallback = ''}) =>
    raw is String ? raw : fallback;
