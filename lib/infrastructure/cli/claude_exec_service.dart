import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'claude_exec_event.dart';
import 'claude_permission.dart';
import 'claude_stream_parser.dart';
import 'host_environment.dart';
import 'text_file.dart';

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
    required this.answerPermission,
    required this.steer,
  });

  final Stream<ClaudeExecEvent> events;
  final Future<void> done;
  final void Function() kill;

  /// Answer a [ClaudePermissionRequested] by the id it carried: an option id to
  /// allow, or null to refuse. The turn is stopped until this is called — and
  /// calling it twice, or for a request the turn has already moved past, does
  /// nothing.
  final void Function(Object id, String? optionId) answerPermission;

  /// Hand the running turn something the user typed while it was working.
  ///
  /// Null back means Claude took it; anything else is the raw reason it didn't,
  /// for the caller to log. It does **not** interrupt: measured against
  /// `claude 2.1.183` on 2026-08-18, a `user` message written mid-turn is
  /// delivered at the next tool boundary and the model changes course inside
  /// the same turn — one `result`, not two — so the work already done is kept.
  /// Arriving after the turn's last tool call, it runs as the next turn in the
  /// same session instead — and the app is still reading, so that answer lands
  /// in the same reply rather than going nowhere.
  final Future<String?> Function(String text) steer;
}

/// Drives Claude Code as a chat agent over `claude -p`. Behind an interface so
/// the sender is tested against a fake that replays scripted turns.
abstract interface class ClaudeExecService {
  /// Run one turn. [resumeSessionId] continues an earlier conversation; null
  /// starts a fresh one. [workdir] is the folder the turn opens in, and
  /// [environment] carries the grid the answer comes from (see
  /// `claudeCodeEnv`). [mcpConfigPath] narrows the turn to the app's own
  /// connectors; null leaves it reading `~/.claude.json`. [chrome] hands the
  /// turn the browser tools of the Claude in Chrome extension. Throws
  /// [ClaudeExecException] if the process won't start.
  ///
  /// [dropEnvironment] names variables the child must **not** inherit. Adding to
  /// [environment] can't express that: the app's own process may already carry
  /// an `ANTHROPIC_*` (a developer running from a terminal that exported one),
  /// and a turn that has to reach Claude Code's own sign-in — the browser
  /// extension refuses any other — needs them gone rather than overwritten.
  ///
  /// [withoutServerWebTools] takes away [kClaudeServerWebTools] for a turn whose
  /// endpoint can't serve them.
  ClaudeExecRun run({
    required String workdir,
    required String prompt,
    required String model,
    required Map<String, String> environment,
    String? resumeSessionId,
    String? mcpConfigPath,
    bool chrome = false,
    bool withoutServerWebTools = false,
    Set<String> dropEnvironment = const {},
  });
}

/// How much of this computer a Claude Code turn may touch **before it asks**.
///
/// `default` is Claude Code's own gate: reading, searching and looking things up
/// run unattended; running a command or changing a file stops and asks. The
/// asking is what `--permission-prompt-tool` turns on — without it this mode is
/// a silent no, and with `bypassPermissions` (what shipped here until
/// 2026-08-18) there was no gate at all: Claude wrote files and ran commands
/// anywhere on this machine with nobody asked first, because `claude -p` was
/// driven one-shot and the app had no channel to answer on. It has one now (see
/// [kClaudePermissionPromptTool]), so the widest grant in the app is gone.
///
/// What the user chose in the composer is applied on top, by the same policy
/// that governs Hermes: `decideHermesPermission` answers the request itself for
/// look-don't-touch and full-access, and puts it to the user in between.
///
/// TODO(BE): a turn on the browser extension lane runs under this too, and the
/// browser it drives is the user's own — every site they are signed in to.
/// Claude Code's site-level permissions (managed inside the extension) are the
/// only gate there, and this app neither sets nor reads them.
const String kClaudePermissionMode = 'default';

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

/// Claude Code's two **server-side** web tools — the ones the model provider
/// runs, not the CLI, so they arrive at the endpoint as tool *types* the other
/// end has to recognise.
///
/// Anthropic's own API does. A relay translating Anthropic Messages into a grid
/// model's chat-completions has nothing to translate them into, and refuses the
/// whole request rather than the tool: `API Error: 400 Unsupported tool type:
/// web_search_20250305`, which fails the turn's step and tells the user nothing
/// they can act on.
///
/// `WebSearch` is the one measured (2026-08-17, a grid model over the relay).
/// `WebFetch` rides with it because it is the same kind of tool under the same
/// versioned naming (`web_fetch_…`), so a relay that can't serve one almost
/// certainly can't serve the other — and being wrong about it costs little,
/// since the `grid-web` skill Grid installs covers searching *and* reading a
/// page, and that is the route the agent takes instead.
const List<String> kClaudeServerWebTools = ['WebSearch', 'WebFetch'];

/// Claude Code's own schedulers, taken away on every turn: none of them can
/// work here, and they fail by *succeeding*.
///
/// `CronCreate` keeps the job in the memory of the process that created it and
/// says so — "session-only, dies when Claude exits". In a REPL that is a fair
/// deal. Here a turn is a `claude -p` that exits the moment the answer is
/// finished, so on 2026-08-19 a user was told two jobs would scan every 30
/// minutes for seven days and both were gone twelve seconds later, with the
/// transcript ending at the message that promised them.
///
/// `ScheduleWakeup` is the same trap wearing the word the user actually says.
/// Taking only the cron tools away on 2026-08-19 left it as the nearest thing
/// to hand, and the next morning it was reached for twice inside eight minutes
/// — 09:22 booking a wake-up for 10:23, 09:29 booking one for 10:30, each into
/// a process that had exited by 09:22:57 and 09:29:43. Both turns ended by
/// telling the user the loop was on.
///
/// Removing the tools is what makes the `grid-schedule` card land: left
/// available, the nearest-to-hand answer is still the one that quietly does
/// nothing. A repeat *inside a chat* is not lost with them — that is `/loop`,
/// which the app owns and the agent paces with a `grid-loop` block.
const List<String> kClaudeSessionSchedulerTools = [
  'CronCreate',
  'CronDelete',
  'CronList',
  'ScheduleWakeup',
];

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
///   overflow an argv limit — and as JSON (`--input-format stream-json`) rather
///   than plain text, because the same pipe carries this app's answers to
///   `--permission-prompt-tool`. Text-mode stdin is one-way, and one-way stdin
///   is why every turn used to run with nobody asked first.
/// - `--mcp-config` with `--strict-mcp-config` narrows the turn to the app's own
///   connectors. See [ClaudeTurnMcpConfig] for why, and why [mcpConfigPath] is
///   nullable: a path that doesn't exist aborts the turn outright, so a failed
///   write must drop **both** flags rather than pass a broken one.
/// - `--chrome` adds the Claude in Chrome extension's browser tools. Off by
///   default because it is only ever right for one lane: the flag costs context
///   on every turn that carries it, and a turn holding the relay's credentials
///   cannot use the extension at all (see [ClaudeBrowserLane]).
/// - `--disallowedTools` takes away [kClaudeSessionSchedulerTools] on every
///   turn, plus the web tools a grid model can't serve — see
///   [withoutServerWebTools]. One flag, not two: it is **variadic**, so a
///   second occurrence would be the CLI's to reconcile rather than ours.
///   Being variadic it also swallows every following token until the next
///   `--flag`, which is safe here because the prompt goes on stdin and this
///   argv carries no positionals — and stays safe only as long as that holds.
List<String> claudeExecArgs({
  required String model,
  String? resumeSessionId,
  String? mcpConfigPath,
  bool chrome = false,
  bool withoutServerWebTools = false,
}) => [
  '-p',
  '--input-format',
  'stream-json',
  '--output-format',
  'stream-json',
  '--include-partial-messages',
  '--verbose',
  '--permission-mode',
  kClaudePermissionMode,
  '--permission-prompt-tool',
  kClaudePermissionPromptTool,
  '--model',
  model,
  if (chrome) '--chrome',
  '--disallowedTools',
  ...kClaudeSessionSchedulerTools,
  if (withoutServerWebTools) ...kClaudeServerWebTools,
  if (mcpConfigPath != null) ...[
    '--mcp-config',
    mcpConfigPath,
    '--strict-mcp-config',
  ],
  if (resumeSessionId != null) ...['--resume', resumeSessionId],
];

/// How long a finished turn's process is given to exit on its own.
///
/// A turn is a `claude -p` that should end with its answer, and the app closes
/// stdin to let it. One that stays is holding something the app has already shut
/// the door on — a `persistent` monitor is how this happens (see
/// [claudeToolRefusal]) — and it stays for good: 2h02m and 684 MB of resident
/// memory on 2026-08-20, waking to ask permissions on a pipe with nobody at the
/// other end and being told "Stream closed" every time.
///
/// Five seconds is room to flush and exit, and not room to stay the night.
const Duration kClaudeExitGrace = Duration(seconds: 5);

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
    bool chrome = false,
    bool withoutServerWebTools = false,
    Set<String> dropEnvironment = const {},
  }) => _ClaudeExecTurn(
    path: _path,
    workdir: workdir,
    prompt: prompt,
    model: model,
    environment: environment,
    resumeSessionId: resumeSessionId,
    mcpConfigPath: mcpConfigPath,
    chrome: chrome,
    withoutServerWebTools: withoutServerWebTools,
    dropEnvironment: dropEnvironment,
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
    required this.chrome,
    required this.withoutServerWebTools,
    required this.dropEnvironment,
  });

  final String path;
  final String workdir;
  final String prompt;
  final String model;
  final Map<String, String> environment;
  final String? resumeSessionId;
  final String? mcpConfigPath;
  final bool chrome;
  final bool withoutServerWebTools;
  final Set<String> dropEnvironment;

  final _events = StreamController<ClaudeExecEvent>();
  final _done = Completer<void>();
  final _parser = ClaudeStreamParser();

  Process? _process;
  IOSink? _stdin;
  var _inputClosed = false;
  var _killed = false;

  /// Counts down [kClaudeExitGrace] once the turn has ended, and stops a
  /// process that has not gone by itself.
  Timer? _exitGrace;

  /// The tool input of every permission request still waiting on an answer, by
  /// the id it arrived with. Kept because a yes has to echo the input back, and
  /// dropped as soon as one is answered — so a second answer to the same request
  /// (a card clicked as the turn ends) writes nothing.
  final _pending = <Object, Map<String, Object?>>{};

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
        chrome: chrome,
        withoutServerWebTools: withoutServerWebTools,
      ),
      workingDirectory: workdir,
      environment: {
        ...Platform.environment,
        'PATH': HostEnvironment.path(),
        ...environment,
      }..removeWhere((name, _) => dropEnvironment.contains(name)),
    ).then(_onStarted).catchError(_onStartError);
    return ClaudeExecRun(
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
    // The handshake the CLI's own SDK opens with, then the turn's prompt. stdin
    // stays **open** afterwards: it is the only way back to a turn that stops to
    // ask, and closing it here is what made every turn one-way.
    _send(claudeInitializeRequest());
    _send(claudeUserMessage(prompt));

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
    if (_readControl(decoded)) return;
    for (final event in _parser.read(decoded)) {
      _note(event);
      _events.add(event);
    }
  }

  /// The control channel — everything that isn't the turn talking.
  ///
  /// A `can_use_tool` request stops the turn dead until it is answered, so it
  /// goes straight to the chat. The rest (the reply to our own handshake, a
  /// request the CLI cancelled, a subtype a later build adds) is swallowed:
  /// returning true keeps it away from the stream parser, which reads content,
  /// not protocol.
  bool _readControl(Map<String, dynamic> decoded) {
    final type = decoded['type'];
    if (type is! String || !type.startsWith('control_')) return false;
    final request = parseClaudePermission(decoded, readBefore: readTextFileNow);
    if (request == null) return true;
    final input = claudePermissionInput(decoded);
    // Answered here rather than put to the user: a yes would not make it work,
    // so the card would be theatre and the no is the honest answer — with the
    // reason, so the model can take the route that does work.
    final refusal = claudeToolRefusal(claudePermissionTool(decoded), input);
    if (refusal != null) {
      _send(
        claudePermissionResponse(
          requestId: '${request.id}',
          optionId: kRefuseOption,
          denyMessage: refusal,
        ),
      );
      return true;
    }
    _pending[request.id] = input;
    _events.add(ClaudePermissionRequested(request));
    return true;
  }

  /// Answer a request the turn is blocked on. Unknown id: already answered, or
  /// belonged to a turn that has since ended — either way there is nobody left
  /// waiting, so this says nothing rather than writing to a dead pipe.
  void answerPermission(Object id, String? optionId) {
    final input = _pending.remove(id);
    if (input == null) return;
    _send(
      claudePermissionResponse(
        requestId: '$id',
        optionId: optionId,
        input: input,
      ),
    );
  }

  /// Put a message in front of the model without stopping the turn — the same
  /// envelope the turn was opened with, on the stdin it is still listening to.
  ///
  /// The one thing that can refuse it is a turn that has already ended: the
  /// answer landing closes stdin ([_endInput]), and writing to a dead pipe would
  /// lose the message rather than queue it.
  Future<String?> steer(String text) async {
    if (text.trim().isEmpty) return 'Nothing to send.';
    if (_inputClosed) return 'The turn had already finished.';
    _send(claudeUserMessage(text));
    return _inputClosed ? 'Claude Code stopped reading its input.' : null;
  }

  void _send(Map<String, Object?> message) {
    if (_inputClosed) return;
    try {
      _stdin?.writeln(jsonEncode(message));
    } on StateError {
      // The process died between the check and the write; its exit is already
      // on its way through [_onExit] and carries the real account.
      _inputClosed = true;
    }
  }

  /// Let the process go. With stdin held open it would sit waiting for another
  /// message long after the answer landed, so the turn's own ending closes it —
  /// and [kClaudeExitGrace] later, so does the process if it is still there.
  void _endInput() {
    if (_inputClosed) return;
    _inputClosed = true;
    _pending.clear();
    try {
      _stdin?.close();
    } on StateError {
      // Already gone.
    }
    if (_killed) return;
    _exitGrace = Timer(kClaudeExitGrace, _stopIfStillRunning);
  }

  /// Stop a process that outlived the turn it was started for.
  ///
  /// Nothing is reported: the turn has already ended and said how, and a second
  /// verdict on a finished turn would be news about the app's own bookkeeping,
  /// not about the work. [_killed] is set first so the exit below reads as ours
  /// rather than as a turn that died without a word.
  void _stopIfStillRunning() {
    if (_process == null || _done.isCompleted) return;
    _killed = true;
    _process?.kill();
    _finish();
  }

  /// Remember what the turn has told us, for the exit path below.
  void _note(ClaudeExecEvent event) {
    switch (event) {
      case ClaudeMessageEvent():
        _spoke = true;
      case ClaudeTurnFailed():
        _spoke = true;
        _failed = true;
        _endInput();
      case ClaudeTurnCompleted():
        _completed = true;
        _endInput();
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
    _endInput();
    _process?.kill();
    _finish();
  }

  void _finish() {
    _exitGrace?.cancel();
    _pending.clear();
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
