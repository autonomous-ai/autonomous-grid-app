import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../logging/app_log.dart';
import 'agent_event.dart';
import 'hermes_permission_policy.dart';
import 'hermes_steer.dart';
import 'host_environment.dart';
import 'stdio_line_writer.dart';

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

/// The turn is over, with ACP's own reason for stopping. The chat needs the
/// difference between an agent that finished and one that was cut off: a to-do
/// step left unticked on a turn the agent ended itself is its own sloppy
/// bookkeeping, not work it abandoned (see [agentTurnStalled]).
class HermesAcpTurnEnded extends HermesAcpEvent {
  const HermesAcpTurnEnded(this.stopReason, {this.toolCalls = 0, this.error});

  /// How many tools the turn called. Hermes caps a turn by its own count of
  /// model round-trips ([kHermesToolCallBudget]) and reports hitting that cap as
  /// an ordinary `end_turn`, so this is the only number the app has to tell a
  /// turn that finished from one that ran out of room — see
  /// [agentSpentToolBudget] for what it may and may not conclude from it.
  final int toolCalls;

  /// Hermes's own words when the turn ended in a JSON-RPC *error* rather than a
  /// stop reason — null on every ordinary turn.
  ///
  /// A turn can fail with nothing streamed at all (a model the assistant can't
  /// reach: it answers the prompt with an error and no updates). Without this
  /// the chat read that as an agent with nothing to say — "The agent didn't
  /// return an answer" — and the reason reached neither the user nor the log.
  final String? error;

  /// ACP's `stopReason` — `end_turn` when the agent decided it was done, or one
  /// of the cut-short reasons below.
  final String stopReason;

  /// Whether the agent ended the turn by itself.
  ///
  /// A reason we don't recognise reads as clean: the prompt response arriving at
  /// all is Hermes reporting the turn over (an aborted one comes back
  /// `cancelled`), and the safe side of guessing wrong here is an answer that
  /// stands rather than a finished answer stamped "stopped before finishing".
  bool get endedCleanly => !_cutShort.contains(stopReason);

  /// The ACP reasons that mean the turn was stopped short of the agent's own
  /// finish line — the user cancelled, the model ran out of room, it refused.
  static const _cutShort = {
    'cancelled',
    'max_tokens',
    'max_turn_requests',
    'refusal',
  };
}

/// How a turn that lost the pipe to Hermes reports itself, ahead of the raw
/// reason. The chat matches on this prefix to say so in plain words, instead of
/// reading a broken pipe as an agent that couldn't answer — a different problem
/// with a different fix (see `friendlyAgentLostContact`).
const String kAcpLostContact = "Grid couldn't reach the assistant's process";

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

  /// Hand the turn in flight something the user typed while it was working.
  ///
  /// Null back means Hermes took it; anything else is the raw reason it didn't,
  /// for the caller to log. It does **not** interrupt — the text is appended to
  /// the last tool result, so the model reads it on its next iteration and the
  /// work already done is kept (see [hermesSteerPrompt]).
  Future<String?> steer(String text);

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
  StdioLineWriter? _writer;
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

  /// Steers waiting on the adapter's answer, by the id they were sent with, and
  /// how many of its acknowledgements are still to be kept out of the answer.
  final _steers = <Object, Completer<String?>>{};
  var _steerAcks = 0;
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
        environment: HostEnvironment.hermesEnvironment(),
      );
    } on ProcessException catch (e) {
      throw HermesAcpException('Hermes could not start: ${e.message}');
    }

    _writer = StdioLineWriter(_process!.stdin, onError: _writeFailed);
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
  Future<String?> steer(String text) {
    if (text.trim().isEmpty) return Future.value('Nothing to send.');
    final session = _sessionId;
    if (_closed || session == null) {
      return Future.value('The Hermes session had already closed.');
    }
    // Nothing is running, so there is nothing to steer: the adapter would take
    // the text as a prompt to run after the next turn, which is not what the
    // caller asked for and would be answered where nobody is listening.
    if (_turnDone == null) return Future.value('No turn was running.');
    final id = _nextId++;
    final answered = Completer<String?>();
    _steers[id] = answered;
    _steerAcks++;
    _write({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'session/prompt',
      'params': {
        'sessionId': session,
        'prompt': [
          {'type': 'text', 'text': hermesSteerPrompt(text)},
        ],
      },
    });
    return answered.future;
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
        // No session means no turn can ever run: Hermes refuses one when it
        // can't resolve a model to answer with ("No LLM provider configured").
        // This used to complete the handshake anyway, leaving a session with a
        // null id — every prompt then returned an empty stream, so a config
        // Hermes couldn't read reached the user as an agent that said nothing.
        if (_sessionId!.isEmpty) {
          final said = _errorOf(message) ?? 'Hermes started no session.';
          _log.failure('agent', 'Hermes refused a session: $said');
          if (!_ready.isCompleted) {
            _ready.completeError(HermesAcpException(said, retryable: false));
          }
          return;
        }
        if (!_ready.isCompleted) _ready.complete();
      default:
        // A steer rides the same channel as a prompt, so it comes back here —
        // and it is not the turn ending. Answering the caller is all there is to
        // do: whether Hermes took the message or not, the turn carries on.
        final steered = _steers.remove(message['id']);
        if (steered != null) {
          if (!steered.isCompleted) steered.complete(_errorOf(message));
          return;
        }
        // A prompt response ends its turn, and its `stopReason` says whether
        // Hermes got to the end of the work or was stopped short of it — or it
        // carries an error, which is the turn failing with nothing streamed.
        if (message['id'] != _turnId) return;
        _emitTurnEnded(message);
        _endTurn();
    }
  }

  void _emitTurnEnded(Map<String, dynamic> message) {
    final error = _errorOf(message);
    // Logged here, where the raw text still exists: what the chat shows is a
    // humanized line, and a log that only repeated it would diagnose nothing.
    if (error != null) {
      _log.failure('agent', 'Hermes ended the turn with an error: $error');
    }
    final events = _events;
    if (events == null || events.isClosed) return;
    final result = message['result'];
    final reason = result is Map ? _str(result['stopReason']) : '';
    // Both numbers, every turn: without them "why did it stop there?" could only
    // be answered by opening Hermes's own SQLite, which is where that question
    // was answered the first time it was asked (§6).
    _log.info(
      'agent',
      'Hermes turn ended: ${reason.isEmpty ? 'no stop reason' : reason} '
          'after ${_tools.length} tool call(s)',
    );
    events.add(
      HermesAcpTurnEnded(reason, toolCalls: _tools.length, error: error),
    );
  }

  /// A JSON-RPC error as one readable line, or null when [message] carries none.
  ///
  /// Reads `data.details` as well as `message`: Hermes puts the sentence that
  /// explains anything ("No LLM provider configured. Run `hermes model`…") in
  /// the data, leaving `message` a bare "Internal error" that names no problem.
  String? _errorOf(Map<String, dynamic> message) {
    final error = message['error'];
    if (error is! Map) return null;
    final summary = _str(error['message'], fallback: 'Hermes failed');
    final data = error['data'];
    final details = data is Map ? _str(data['details']) : '';
    return details.isEmpty ? summary : '$summary: $details';
  }

  /// Stop claiming that earlier tool calls are still running.
  ///
  /// Hermes does not reliably close a tool call. Its ACP adapter ignores the
  /// agent's own `tool.completed` event outright — `_tool_progress` returns
  /// unless the event is `tool.started` — and closes calls only from
  /// `step_callback`, which fires when the model makes its *next* request and
  /// matches ids through a FIFO queue keyed by **tool name**. So a call whose
  /// name is reported differently on the way out, and every call in the last
  /// round before the turn ends, never gets its update.
  ///
  /// Measured on one saved turn: of nine steps, every one of the five `read`
  /// calls was left running, against two of four `execute` calls. On screen
  /// that is a spinner that turns for the rest of the conversation.
  ///
  /// So the app settles them itself, as [AgentActivityStatus.unknown] — not
  /// done. Nothing here knows how they went, and a tick would vouch for a tool
  /// that may have failed.
  ///
  /// Safe against the case where they really *are* still running: Hermes can
  /// run tools in parallel, and a step that does report back later simply
  /// overwrites this — the feed keys rows by id, so the real outcome wins
  /// whenever it arrives. Guessing early costs a corrected row; not guessing
  /// costs a spinner that never stops.
  /// [except] is the call that has just started, which is genuinely running.
  /// Null when the trigger is the agent writing rather than a new call.
  ///
  /// Returns early when nothing is running, because the message-chunk caller
  /// reaches this on **every token** of the answer: the common case has to cost
  /// a map scan and no allocation.
  void _retireRunning(
    StreamController<HermesAcpEvent> events, {
    String? except,
  }) {
    var running = false;
    for (final step in _tools.values) {
      if (step.status == AgentActivityStatus.running && step.id != except) {
        running = true;
        break;
      }
    }
    if (!running) return;

    for (final entry in _tools.entries.toList()) {
      final step = entry.value;
      if (entry.key == except) continue;
      if (step.status != AgentActivityStatus.running) continue;
      final settled = step.settled(status: AgentActivityStatus.unknown);
      _tools[entry.key] = settled;
      events.add(HermesAcpActivity(settled));
    }
  }

  void _handleUpdate(Object? raw) {
    if (raw is! Map) return;
    final events = _events;
    if (events == null || events.isClosed) return;
    switch (raw['sessionUpdate']) {
      case 'tool_call':
        final id = _str(raw['toolCallId']);
        // A new call means the ones before it are no longer the step in hand.
        _retireRunning(events, except: id);
        final activity = AgentActivity(
          id: id,
          kind: _activityKind(raw['kind']),
          label: _str(raw['title'], fallback: 'tool'),
          status: AgentActivityStatus.running,
          // ACP's own kind word (`read`, `edit`, `execute`, `search`) — the
          // nearest thing Hermes gives to a tool name, and what lets a run of
          // steps summarise as "read 4 files" rather than "used 4 tools".
          tool: _str(raw['kind'], fallback: 'tool'),
          // Hermes doesn't send `rawInput` for its own tools — its ACP adapter
          // attaches that only in the generic fallback branch, and every
          // built-in tool is excluded from it. What it sends instead is a
          // *rendered* request in `content`: `$ <command>` for the terminal,
          // `Searching the web for: …`, the python source for a script. So the
          // fold shows Hermes's own wording rather than an arguments object,
          // and two tools (read_file, web_extract) deliberately send nothing at
          // all — their title already names the file.
          request: clipToolPayload(_toolContentText(raw['content'])),
        );
        _tools[id] = activity;
        events.add(HermesAcpActivity(activity));
      case 'tool_call_update':
        final id = _str(raw['toolCallId']);
        final prior = _tools[id];
        final kind = prior?.kind ?? _activityKind(raw['kind']);
        // The update carries the tool's outcome the same way: a per-tool
        // rendering of the result in `content`. It is the very text
        // [parseWebSearchSources] already mines its citations out of, so this is
        // reading what was there rather than asking Hermes for anything new.
        final activity =
            prior?.settled(
              status: _status(raw['status']),
              result: _toolContentText(raw['content']),
            ) ??
            AgentActivity(
              id: id,
              kind: kind,
              label: 'tool',
              status: _status(raw['status']),
              result: clipToolPayload(_toolContentText(raw['content'])),
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
          final said = content['text'] as String;
          // The adapter answers a `/steer` in the agent's own voice, on the
          // running turn — so its acknowledgement would otherwise be pasted
          // into the middle of the answer the user is reading. Kept in the log,
          // which is where "did it get my message?" is answered from.
          if (_steerAcks > 0 && isHermesSteerAck(said)) {
            _steerAcks--;
            _log.info(
              'agent',
              'Hermes on a mid-answer message: ${said.trim()}',
            );
            return;
          }
          // The model is writing again, so the round of tools it was waiting on
          // has come back. This is the half [_retireRunning] cannot catch from
          // a later `tool_call`: the tools of the *last* round have no call
          // after them, and without this their spinners turn all the way
          // through the answer being written over them.
          _retireRunning(events);
          events.add(HermesAcpMessage(said));
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

    final request = parseAgentPermission(id: id, params: params);

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
        // change can be recorded for undo. Reads and commands are nothing to
        // undo.
        if (toolKind != 'edit') return;
        final events = _events;
        if (request == null || events == null || events.isClosed) return;
        events.add(HermesAcpEdit(request));
      case HermesRefuse(:final optionId):
        answerPermission(id, optionId);
        _blocked(id, label);
      case HermesAskUser():
        final events = _events;
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
    // Nobody is left to answer a steer sent as the turn was ending — say so
    // rather than leaving the caller waiting on a future that never completes.
    for (final waiting in _steers.values) {
      if (!waiting.isCompleted) waiting.complete('The turn ended first.');
    }
    _steers.clear();
    _steerAcks = 0;
    final done = _turnDone;
    _turnDone = null;
    if (done != null && !done.isCompleted) done.complete();
  }

  // Hermes reads newline-delimited JSON-RPC from stdin, and the writer flushes
  // each line without letting the next one race that flush — see
  // [StdioLineWriter] for what the race cost.
  void _write(Map<String, Object?> message) {
    if (_closed) return;
    _writer?.write('${jsonEncode(message)}\n');
  }

  /// A message that never reached Hermes: the pipe broke, or the process died
  /// under it. Whatever it was waiting on — a permission answer, the prompt
  /// itself — it waits on forever, so end the turn now and say why. This used to
  /// surface only as minutes of silence and then the idle watchdog's line, which
  /// blamed the model for a pipe the app had dropped.
  void _writeFailed(Object error) {
    // A stopped session kills the process under any queued line; that is the
    // stop working, not a fault to report.
    if (_closed) return;
    _log.failure('agent', 'Hermes never got a message: $error');
    final events = _events;
    if (events != null && !events.isClosed) {
      events.add(
        HermesAcpTurnEnded('cancelled', error: '$kAcpLostContact: $error'),
      );
    }
    // A session we can't write to is over: let go of the process so the next
    // message starts a fresh one rather than talking into a pipe nobody reads.
    unawaited(close());
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
