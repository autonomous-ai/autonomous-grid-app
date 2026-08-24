import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'host_environment.dart';

/// How long a finished turn's process is given to go on its own after Stop.
///
/// The app asks first (SIGTERM) so the CLI can flush what it was writing and
/// tidy up its own session files; a process still there afterwards is holding
/// something it will not let go of, and is taken down.
const Duration kRawAgentExitGrace = Duration(seconds: 5);

/// One agent turn as the CLI itself printed it.
///
/// [output] carries stdout and stderr merged in arrival order, decoded as UTF-8
/// and otherwise untouched — no line is dropped, rewritten, or read for meaning.
/// That is the whole point of this lane: the chat shows what the agent returned
/// rather than the app's account of it.
///
/// It is also the cost, and it is not small. A text-mode turn has no channel to
/// ask permission on, no session id to resume from, and no tool events to draw,
/// because all three of those only ever existed inside the JSON the app no
/// longer asks for. See [RawAgentService].
class RawAgentRun {
  const RawAgentRun({
    required this.output,
    required this.done,
    required this.kill,
  });

  /// The turn's own words, as they arrive. Errors on this stream are the app's
  /// own — a CLI that could not be started at all.
  final Stream<String> output;

  /// The process's exit code once it has gone. Anything but 0 is a failed turn.
  final Future<int> done;

  /// Stop the turn now: the user pressed Stop, or left the chat.
  final void Function() kill;
}

/// The CLI could not be started — the binary is missing, or the OS refused it.
///
/// Distinct from a turn that ran and failed: there is no agent output to show
/// for this one, so the sender has nothing to fall back on but [message].
class RawAgentException implements Exception {
  const RawAgentException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Runs one agent turn in the agent's **own text mode** and hands back what it
/// printed, unparsed.
///
/// One implementation for every agent: what differs between Claude Code and
/// Codex is the argv (see `raw_agent_argv.dart`), not how a turn is spawned, so
/// "spawn, feed the prompt, read what comes back" is written once. The seam is
/// an interface so a sender can be tested against a fake without a CLI on the
/// machine.
abstract interface class RawAgentService {
  /// Start [args] in [workdir], with [prompt] on stdin.
  ///
  /// [environment] is layered over this process's own; [dropEnvironment] names
  /// variables to take *away* from the child (the browser lane runs without the
  /// relay's credentials).
  RawAgentRun run({
    required String workdir,
    required String prompt,
    required List<String> args,
    Map<String, String> environment = const {},
    Set<String> dropEnvironment = const {},
  });
}

/// Real implementation: spawns the CLI at [_path] and streams it back verbatim.
class RawAgentServiceImpl implements RawAgentService {
  const RawAgentServiceImpl(this._path);

  final String _path;

  @override
  RawAgentRun run({
    required String workdir,
    required String prompt,
    required List<String> args,
    Map<String, String> environment = const {},
    Set<String> dropEnvironment = const {},
  }) => _RawAgentTurn(
    path: _path,
    workdir: workdir,
    prompt: prompt,
    args: args,
    environment: environment,
    dropEnvironment: dropEnvironment,
  ).start();
}

class _RawAgentTurn {
  _RawAgentTurn({
    required this.path,
    required this.workdir,
    required this.prompt,
    required this.args,
    required this.environment,
    required this.dropEnvironment,
  });

  final String path;
  final String workdir;
  final String prompt;
  final List<String> args;
  final Map<String, String> environment;
  final Set<String> dropEnvironment;

  final _output = StreamController<String>();
  final _done = Completer<int>();

  Process? _process;
  var _killed = false;
  Timer? _exitGrace;

  RawAgentRun start() {
    Process.start(
      path,
      args,
      workingDirectory: workdir,
      // The packaged app inherits a minimal PATH, so a CLI that shells out to
      // git or node finds nothing without this (see [HostEnvironment]).
      environment: {
        // Minus whichever Claude Code session started the app, if one did — the
        // turn starting here is not that session (see
        // [withoutInheritedAgentSession]).
        ...withoutInheritedAgentSession(Platform.environment),
        'PATH': HostEnvironment.path(),
        ...environment,
      }..removeWhere((name, _) => dropEnvironment.contains(name)),
    ).then(_onStarted).catchError(_onStartError);
    return RawAgentRun(output: _output.stream, done: _done.future, kill: kill);
  }

  void _onStarted(Process process) {
    if (_killed) {
      process.kill();
      return;
    }
    _process = process;
    // The prompt goes on stdin rather than in argv so a long replayed history
    // can't overflow an argv limit. Closed straight after: with no permission
    // channel left there is nothing else to send, and a CLI reading stdin waits
    // for the close before it starts.
    process.stdin
      ..write(prompt)
      ..close().catchError((Object _) {});

    // Both pipes into one stream, in arrival order and undivided: the decoder
    // spans chunk boundaries, so a multi-byte character split across two reads
    // still arrives as one character rather than two replacement glyphs.
    final pipes = <Future<void>>[_pipe(process.stdout), _pipe(process.stderr)];
    process.exitCode.then((code) async {
      await Future.wait(pipes);
      _finish(code);
    });
  }

  Future<void> _pipe(Stream<List<int>> pipe) => pipe
      .transform(utf8.decoder)
      .forEach((chunk) {
        if (!_output.isClosed) _output.add(chunk);
      })
      .catchError((Object _) {});

  void _onStartError(Object error) {
    final message = error is ProcessException ? error.message : '$error';
    if (!_output.isClosed) _output.addError(RawAgentException(message));
    _finish(127);
  }

  void _finish(int code) {
    _exitGrace?.cancel();
    if (!_done.isCompleted) _done.complete(code);
    if (!_output.isClosed) _output.close();
  }

  void kill() {
    if (_killed) return;
    _killed = true;
    final process = _process;
    if (process == null) return;
    process.kill();
    _exitGrace = Timer(kRawAgentExitGrace, () {
      process.kill(ProcessSignal.sigkill);
    });
  }
}
