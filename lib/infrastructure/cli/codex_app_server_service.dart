import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'agent_event.dart';
import 'codex_app_server_parser.dart';
import 'codex_approval.dart';
import 'codex_agent_service.dart';
import 'host_environment.dart';

/// How much of this computer a Codex turn may touch, and when it must stop and
/// ask — derived from the mode the chat is in, and nothing else.
///
/// This is the whole point of the app-server transport. The old one
/// (`codex exec`) had no channel to ask on, so every turn ran under
/// `danger-full-access`: Codex wrote files and ran commands anywhere on this
/// machine with nobody asked first, whatever the composer said. Now the mode is
/// real — look-don't-touch can't write, "ask first" escalates to a card, and
/// full access is a choice the user made rather than the only setting there was.
///
/// `untrusted` is Codex's own "ask unless you are sure it is safe": it still
/// decides the trivial cases itself (a bare `echo` never reaches the user), which
/// is exactly what Hermes does over ACP. Copy must not promise otherwise.
({String policy, String sandbox}) codexApprovalPolicy(AgentApprovalMode mode) =>
    switch (mode) {
      // Nothing to approve, because nothing may be touched.
      AgentApprovalMode.readOnly => (policy: 'never', sandbox: 'read-only'),
      // The planning turn is forced read-only by the sender, so this is only
      // ever the turn that carries a plan out.
      AgentApprovalMode.plan || AgentApprovalMode.ask => (
        policy: 'untrusted',
        sandbox: 'workspace-write',
      ),
      AgentApprovalMode.full => (
        policy: 'never',
        sandbox: 'danger-full-access',
      ),
    };

/// The argv for one turn's server. Pure, and unit-tested, because the failure
/// mode is silent: a mistyped flag looks exactly like a model that wouldn't
/// answer.
///
/// [config] is the run's configuration in `-c` form — the grid, the model, the
/// provider to reach them through (`codexGridOverrides`) — so a turn answers on
/// the app's grid without the user's own `~/.codex/config.toml` being rewritten.
/// The sandbox is **not** among them any more: it is negotiated per thread now
/// (see [codexApprovalPolicy]), where it can follow the chat's mode.
List<String> codexAppServerArgs({required List<String> config}) => [
  'app-server',
  '--stdio',
  for (final override in config) ...['-c', override],
];

/// How long the three calls between Send and the model may take before the app
/// stops waiting. Generous, because it covers a cold start; finite, because a
/// server that never answers would otherwise leave the chat working forever.
const Duration kCodexHandshakeTimeout = Duration(seconds: 45);

/// What the user is told when it runs out.
const String kCodexNoHandshake =
    "Codex started but didn't answer. Try sending again.";

/// What to tell the user when `codex app-server` isn't there.
///
/// It is marked experimental and arrived in a build newer than some installs, so
/// this is a real state, not a theoretical one — and it must be said plainly
/// rather than papered over by falling back to the transport that couldn't ask.
/// Silently running with full access again would be the app promising to ask and
/// then not asking.
const String kCodexTooOld =
    'This copy of Codex is too old to ask before it runs commands. '
    'Update Codex from the Agents tab and try again.';

/// Drives Codex over `codex app-server` — one server per turn, speaking JSON-RPC
/// on stdio.
///
/// One *per turn*, not one per conversation: continuity comes from resuming the
/// thread by id, exactly as the old transport did, so the session bookkeeping
/// above this is unchanged. A longer-lived server would also keep its MCP
/// children alive between turns, which this doesn't buy — a deliberate omission,
/// kept out of a change that is already a transport swap.
class CodexAppServerService implements CodexService {
  const CodexAppServerService(this._path);

  final String _path;

  @override
  CodexRun run({
    required String workdir,
    required String prompt,
    required List<String> config,
    required Map<String, String> environment,
    required AgentApprovalMode approval,
    String? resumeThreadId,
  }) => _CodexAppServerTurn(
    path: _path,
    workdir: workdir,
    prompt: prompt,
    config: config,
    environment: environment,
    approval: approval,
    resumeThreadId: resumeThreadId,
  ).start();
}

/// The JSON-RPC ids the handshake sends. Fixed, because the three of them run
/// in order and the replies are told apart by which one is outstanding; a steer
/// takes an id of its own from [_firstSteerId] up, since any number of those can
/// arrive while the turn runs.
const int _initializeId = 1;
const int _threadId = 2;
const int _turnId = 3;
const int _firstSteerId = 4;

/// The `turn/steer` call: text for the turn already in flight.
///
/// Pure, and unit-tested, for the same reason [codexAppServerArgs] is — the
/// fields were read off the running binary (`codex-cli 0.144.6`, 2026-08-18: an
/// empty `params` names each missing one in turn), and a build that renames one
/// would otherwise refuse the message with nobody the wiser.
///
/// [turnId] is the turn the caller believes is running. Codex checks it and
/// answers `activeTurnNotSteerable` rather than steering whatever turn happens
/// to be current, which is what keeps a message typed during one turn out of the
/// next one.
Map<String, Object?> codexSteerParams({
  required String threadId,
  required String turnId,
  required String text,
}) => {
  'threadId': threadId,
  'expectedTurnId': turnId,
  'input': [
    {'type': 'text', 'text': text},
  ],
};

class _CodexAppServerTurn {
  _CodexAppServerTurn({
    required this.path,
    required this.workdir,
    required this.prompt,
    required this.config,
    required this.environment,
    required this.approval,
    required this.resumeThreadId,
  });

  final String path;
  final String workdir;
  final String prompt;
  final List<String> config;
  final Map<String, String> environment;
  final AgentApprovalMode approval;
  final String? resumeThreadId;

  final _events = StreamController<CodexEvent>();
  final _done = Completer<void>();

  /// The answer so far, by the id of the message item carrying it.
  final _messages = <String, String>{};

  /// Items seen this turn, by id — read back when an approval request names one
  /// without describing it (a file change carries its patch here, not there).
  final _items = <String, Map<String, dynamic>>{};

  /// Approval requests still waiting on an answer, by their JSON-RPC id.
  final _pending = <Object, String>{};

  /// Steers waiting on the server's yes or no, by the id they were sent with.
  final _steers = <Object, Completer<String?>>{};
  var _nextSteerId = _firstSteerId;

  /// The thread and turn a steer has to name — known once the server has
  /// confirmed each, and null before that (there is nothing to steer yet).
  String? _thread;
  String? _turn;

  Process? _process;
  IOSink? _stdin;
  Timer? _handshake;
  var _inputClosed = false;
  var _killed = false;
  var _turnStarted = false;

  final _stderr = <String>[];
  static const _stderrKept = 20;

  var _spoke = false;
  var _failed = false;
  var _completed = false;

  CodexRun start() {
    Process.start(
      path,
      codexAppServerArgs(config: config),
      workingDirectory: workdir,
      environment: {
        ...Platform.environment,
        'PATH': HostEnvironment.path(),
        ...environment,
      },
    ).then(_onStarted).catchError(_onStartError);
    return CodexRun(
      events: _events.stream,
      done: _done.future,
      kill: kill,
      answerPermission: answerPermission,
      steer: steer,
    );
  }

  void _onStarted(Process process) {
    if (_killed) {
      process.kill();
      return;
    }
    _process = process;
    _stdin = process.stdin;
    _call(_initializeId, 'initialize', {
      'clientInfo': {'name': 'grid-app', 'version': '1'},
    });
    // Three calls stand between Send and the model, and a server that answers
    // none of them leaves the chat working forever with nothing to show. Long
    // enough for a cold start on a slow disk, short enough to be an answer.
    _handshake = Timer(kCodexHandshakeTimeout, () {
      if (_turnStarted) return;
      _fail(kCodexNoHandshake);
    });

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
      _events.addError(CodexException('Codex could not start: $message'));
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
    final method = decoded['method'];
    if (method is String) {
      final params = decoded['params'];
      final fields = params is Map
          ? params.cast<String, dynamic>()
          : <String, dynamic>{};
      if (decoded.containsKey('id')) {
        _onServerRequest(decoded['id'] as Object, method, fields);
        return;
      }
      _onNotification(method, fields);
      return;
    }
    _onReply(decoded);
  }

  /// A reply to one of our own three calls. Each one starts the next step, so
  /// the turn is only ever as far along as the server has confirmed.
  void _onReply(Map<String, dynamic> decoded) {
    final error = decoded['error'];
    // A refused steer is not a failed turn: the answer the user is watching
    // carries on either way, so this reply goes back to whoever sent the
    // message and no further.
    final steered = _steers.remove(decoded['id']);
    if (steered != null) {
      if (!steered.isCompleted) {
        steered.complete(
          error is Map
              ? '${error['message'] ?? 'Codex would not take the message.'}'
              : null,
        );
      }
      return;
    }
    if (error is Map) {
      _fail('${error['message'] ?? 'Codex refused the request.'}');
      return;
    }
    final result = decoded['result'];
    final fields = result is Map ? result : const {};
    switch (decoded['id']) {
      case _initializeId:
        _startThread();
      case _threadId:
        final thread = fields['thread'];
        final id = thread is Map ? thread['id'] : resumeThreadId;
        if (id is! String || id.isEmpty) {
          _fail('Codex started a conversation without naming it.');
          return;
        }
        _thread = id;
        _events.add(CodexThreadStarted(id));
        _startTurn(id);
      case _turnId:
        // The turn is under way; everything from here is a notification. Its id
        // comes back with this reply and nowhere else the app reads, and a steer
        // has to name it — see [codexSteerParams].
        final turn = fields['turn'];
        final id = turn is Map ? turn['id'] : null;
        if (id is String && id.isNotEmpty) _turn = id;
        _turnStarted = true;
        _handshake?.cancel();
    }
  }

  void _startThread() {
    final gate = codexApprovalPolicy(approval);
    final resume = resumeThreadId;
    _call(_threadId, resume == null ? 'thread/start' : 'thread/resume', {
      'threadId': ?resume,
      'cwd': workdir,
      'approvalPolicy': gate.policy,
      'sandbox': gate.sandbox,
    });
  }

  void _startTurn(String thread) => _call(_turnId, 'turn/start', {
    'threadId': thread,
    'input': [
      {'type': 'text', 'text': prompt},
    ],
  });

  void _onNotification(String method, Map<String, dynamic> params) {
    // Remember every item as it opens: an approval request for a file change
    // names the item but doesn't describe it.
    if (method == 'item/started' || method == 'item/completed') {
      final item = params['item'];
      if (item is Map && item['id'] is String) {
        _items['${item['id']}'] = item.cast<String, dynamic>();
      }
    }
    final event = parseCodexAppServerEvent(
      method: method,
      params: params,
      messages: _messages,
    );
    if (event == null) return;
    _note(event);
    _events.add(event);
  }

  /// The server is asking. Anything this app can't answer is declined with a
  /// JSON-RPC error rather than a made-up yes — and said out loud in the stderr
  /// tail, so a request nobody handled doesn't look like a turn that stalled.
  void _onServerRequest(Object id, String method, Map<String, dynamic> params) {
    final request = parseCodexApproval(
      id: id,
      method: method,
      params: params,
      item: _items['${params['itemId'] ?? ''}'],
    );
    if (request == null) {
      _reply(id, error: 'grid-app does not answer $method');
      return;
    }
    _pending[id] = method;
    _events.add(CodexPermissionRequested(request));
  }

  /// Put a message in front of the model without stopping the turn.
  ///
  /// Refused — with a reason for the caller's log — while the handshake is still
  /// running: there is no turn to steer until the server has named one, and
  /// sending anyway would land the message in whatever ran next.
  Future<String?> steer(String text) {
    if (text.trim().isEmpty) return Future.value('Nothing to send.');
    if (_inputClosed) return Future.value('The turn had already finished.');
    final thread = _thread;
    final turn = _turn;
    if (thread == null || turn == null) {
      return Future.value('Codex had not started the turn yet.');
    }
    final id = _nextSteerId++;
    final answered = Completer<String?>();
    _steers[id] = answered;
    _call(
      id,
      'turn/steer',
      codexSteerParams(threadId: thread, turnId: turn, text: text),
    );
    return answered.future;
  }

  void answerPermission(Object id, String? optionId) {
    final method = _pending.remove(id);
    if (method == null) return;
    _reply(
      id,
      result: codexApprovalResult(method: method, optionId: optionId),
    );
  }

  void _call(int id, String method, Map<String, Object?> params) =>
      _send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});

  void _reply(Object id, {Map<String, Object?>? result, String? error}) =>
      _send({
        'jsonrpc': '2.0',
        'id': id,
        if (error == null)
          'result': result ?? const <String, Object?>{}
        else
          'error': {'code': -32601, 'message': error},
      });

  void _send(Map<String, Object?> message) {
    if (_inputClosed) return;
    try {
      _stdin?.writeln(jsonEncode(message));
    } on StateError {
      _inputClosed = true;
    }
  }

  void _fail(String message) {
    if (_events.isClosed) return;
    _failed = true;
    _spoke = true;
    _events.add(CodexTurnFailed(message));
    _endInput();
  }

  void _note(CodexEvent event) {
    switch (event) {
      case CodexMessageEvent():
        _spoke = true;
      case CodexTurnFailed():
        _spoke = true;
        _failed = true;
        _endInput();
      case CodexTurnCompleted():
        _completed = true;
        _endInput();
      default:
    }
  }

  /// The turn is over: let the server go. It would otherwise sit holding the
  /// thread open, waiting for a turn that isn't coming.
  void _endInput() {
    if (_inputClosed) return;
    _inputClosed = true;
    _handshake?.cancel();
    _pending.clear();
    try {
      _stdin?.close();
    } on StateError {
      // Already gone.
    }
    _process?.kill();
  }

  /// A server that dies without a word — a config Codex won't load, a
  /// subcommand this build doesn't have, a panic — used to reach the chat as "no
  /// answer" with the reason unread in [_stderr]. Hand that reason over.
  void _onExit(int code) {
    if (_killed || _events.isClosed) {
      _finish();
      return;
    }
    if (code == 0 && !_failed && !_completed) {
      _events.add(const CodexTurnCompleted());
    } else if (!_spoke && !_completed && code != 0) {
      // A turn that ended by itself is *this* code killing the server it no
      // longer needs — the non-zero exit that follows is ours, not a failure to
      // report over a turn that already finished.
      final tail = _stderr.join('\n').trim();
      _events.add(CodexTurnFailed(codexStartupFailure(tail, code)));
    }
    _finish();
  }

  void kill() {
    _killed = true;
    _endInput();
    _process?.kill();
    _finish();
  }

  void _finish() {
    _pending.clear();
    // Nobody is left to answer a steer sent as the turn was ending — say so
    // rather than leaving the caller waiting on a future that never completes.
    for (final waiting in _steers.values) {
      if (!waiting.isCompleted) waiting.complete('The turn ended first.');
    }
    _steers.clear();
    if (_done.isCompleted) return;
    _done.complete();
    if (!_events.isClosed) _events.close();
  }
}

/// What a dead server's last words mean. A build without `app-server` says so in
/// its own words ("unrecognized subcommand"), which names a fix the user can
/// act on — so it is worth recognising rather than passing on verbatim.
String codexStartupFailure(String stderrTail, int code) {
  final tail = stderrTail.trim();
  final unknown =
      tail.contains('unrecognized subcommand') ||
      tail.contains('unexpected argument');
  if (unknown) return kCodexTooOld;
  return tail.isEmpty ? 'Codex exited with code $code.' : tail;
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
