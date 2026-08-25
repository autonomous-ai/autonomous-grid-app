import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

import '../../infrastructure/cli/host_environment.dart';
import '../theme/app_theme.dart';
import 'terminal_shell.dart';

/// What the shell behind a terminal is doing.
sealed class ShellState {
  const ShellState();
}

/// Spawned but not started: the view hasn't been laid out yet, so the shell
/// hasn't been told how wide its screen is.
class ShellIdle extends ShellState {
  const ShellIdle();
}

class ShellRunning extends ShellState {
  const ShellRunning({required this.pid});

  final int pid;
}

/// The shell ended — `exit`, a `kill`, or a crash. Not an error state: leaving a
/// terminal is how a terminal is meant to end.
class ShellExited extends ShellState {
  const ShellExited({required this.code});

  final int code;
}

/// The shell couldn't be opened at all. [message] is what the user is shown;
/// the raw failure goes to the log through the caller's `onError`.
class ShellFailed extends ShellState {
  const ShellFailed({required this.message});

  final String message;
}

/// One terminal: the screen the user reads, and the shell running behind it.
///
/// Holds the emulator ([terminal]) rather than rebuilding it per frame, because
/// the screen *is* the state — scrollback, cursor, what a half-typed command
/// looks like. A widget that owned it would lose all of that on every tab
/// switch.
///
/// Deliberately not a Riverpod notifier: several of these are open at once and
/// the panel shows one, so they are values a controller keeps a list of. What
/// they can't do is publish themselves — [onChanged] is how the controller
/// hears that a shell started or died.
class TerminalSession {
  TerminalSession({
    required this.id,
    required this.workdir,
    ShellCommand? command,
    Map<String, String> environment = const {},
    this.onChanged,
  }) : _command = command,
       _environment = environment;

  /// The id of the panel tab this terminal belongs to.
  final String id;

  /// The folder the shell starts in — the same one the assistant is working in,
  /// so a command here acts on the files the chat beside it is talking about.
  final String workdir;

  /// What to run, or null for the user's own login shell — which is what a
  /// Terminal tab wants and what [resolveShell] picks.
  ///
  /// An agent chat passes its CLI here instead ([agentTerminalCommand]): the
  /// point of that lane is that the user drives the agent's own interface, and
  /// the only difference from a Terminal tab is which program is on the other
  /// end of the pty.
  ShellCommand? _command;
  ShellCommand? get command => _command;

  /// Variables layered over the app's own for this session — the grid a chat
  /// answers on, and the key to reach it. Empty for a plain shell.
  ///
  /// Applied *under* `TERM`, so a caller cannot accidentally hand the program a
  /// terminal type that turns off colour and the cursor.
  Map<String, String> _environment;
  Map<String, String> get environment => _environment;

  /// Fires when [shell] moves, so the controller can republish its state.
  final VoidCallback? onChanged;

  /// Lines kept above the screen. Ten thousand is what VS Code keeps, and a
  /// build log is exactly the case that needs them.
  static const _scrollback = 10000;

  final Terminal terminal = Terminal(maxLines: _scrollback);
  final TerminalController controller = TerminalController();

  ShellState _shell = const ShellIdle();
  ShellState get shell => _shell;

  Pty? _pty;
  StreamSubscription<String>? _output;

  /// Opens the shell, unless one is already running.
  ///
  /// [onError] carries the raw failure to the log: the sentence written onto the
  /// screen is for the user, and a log that only repeats it diagnoses nothing.
  void start({required void Function(Object error, StackTrace stack) onError}) {
    if (_shell is ShellRunning) return;

    // A project whose folder has been moved or deleted is a state this app
    // already knows about (`missingProjectFoldersProvider`), and a pty told to
    // start in a folder that isn't there fails somewhere far less legible.
    if (!Directory(workdir).existsSync()) {
      _fail(
        message: 'That folder is no longer on this computer.',
        line: "Can't open a terminal: $workdir is no longer there.",
      );
      onChanged?.call();
      return;
    }

    final command =
        _command ??
        resolveShell(
          environment: Platform.environment,
          operatingSystem: Platform.operatingSystem,
        );
    // A pty on Windows is handed a command line rather than an argv, and
    // `flutter_pty` builds it by joining these two with spaces, quoting nothing
    // and naming the program twice — see [windowsPtyCommand] for what that
    // costs and why `cmd /c` is what gets past it.
    final spawn = Platform.isWindows ? windowsPtyCommand(command) : command;
    try {
      final pty = Pty.start(
        spawn.executable,
        arguments: spawn.arguments,
        workingDirectory: workdir,
        // The app's own environment, then this session's, plus the two variables
        // that decide whether the program believes it has a terminal at all.
        // `flutter_pty` sets both, but only for the variables it copies itself —
        // spreading ours over the top would otherwise hand the program whatever
        // `TERM` the app inherited (`dumb`, when launched from an IDE), and a
        // `dumb` terminal turns off colour, the cursor and every full-screen
        // program. Which is to say: the whole agent TUI.
        environment: {
          // Minus whichever Claude Code session started the app, if one did:
          // its name and its message pipe are no part of the session opening
          // here (see [withoutInheritedAgentSession]).
          ...withoutInheritedAgentSession(Platform.environment),
          ..._environment,
          'TERM': 'xterm-256color',
          'TERM_PROGRAM': 'Grid',
          // What colour this terminal is *on*, which is the only way a TUI can
          // know. Read out of `claude` 2.1.243: it takes the last `;`-separated
          // field as the background's ANSI index and answers `r <= 6 || r === 8
          // ? "dark" : "light"` — and returns nothing at all when the variable
          // is unset, which is how Claude Code came to draw its dark theme on
          // the app's white window and put a black slab across the user's own
          // message. 0 is black, 15 is white; the foreground half is the
          // opposite and nothing reads it.
          'COLORFGBG': AppTheme.isDark ? '15;0' : '0;15',
        },
        columns: terminal.viewWidth,
        rows: terminal.viewHeight,
      );
      _pty = pty;
      _shell = ShellRunning(pid: pty.pid);

      // A pty carries no encoding of its own, and a build log is full of
      // multi-byte glyphs (✓, ✗, box drawing). `allowMalformed` keeps a
      // character split across two reads from throwing away the whole chunk.
      _output = pty.output
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(terminal.write);

      unawaited(pty.exitCode.then((code) => _onExit(pty, code)));

      terminal.onOutput = (data) =>
          pty.write(const Utf8Encoder().convert(data));
      // xterm counts columns then rows; a pty is sized rows then columns.
      // Passing them straight through swaps the two on every resize.
      terminal.onResize = (w, h, pw, ph) => pty.resize(h, w);
    } on Object catch (error, stack) {
      onError(error, stack);
      _fail(
        message: "Couldn't start ${command.executable} here.",
        line: "Couldn't start ${command.executable} in $workdir.",
      );
    }
    onChanged?.call();
  }

  /// Puts [text] where the cursor is and leaves it there, unsent — what
  /// dropping a file onto a terminal does, and what an agent's composer needs
  /// when the user is still writing the rest of the line.
  ///
  /// Returns false when no program is running: there is nobody to type at.
  bool insert(String text) {
    final pty = _pty;
    if (pty == null || _shell is! ShellRunning) return false;
    pty.write(const Utf8Encoder().convert(text));
    return true;
  }

  /// Opens a fresh shell in a terminal whose last one ended, keeping the
  /// scrollback above it — the transcript of what went wrong is usually why the
  /// user is starting another.
  void restart({
    required void Function(Object error, StackTrace stack) onError,
  }) {
    if (_shell is ShellRunning) return;
    _output?.cancel();
    _output = null;
    _pty = null;
    terminal.write('\r\n');
    start(onError: onError);
  }

  /// Kills what is running and starts [command] in its place, on this same
  /// screen.
  ///
  /// **Not [dispose] followed by a new session, and that is the whole point.**
  /// Replacing the session object swaps the widget under the chat for
  /// "Starting…" and back, so the terminal's whole subtree is torn down and
  /// rebuilt mid-frame — and `xterm`'s `TerminalView` keeps three `GlobalKey`s
  /// in its state. Changing the model and pressing Restart brought the app down
  /// on `_elements.contains(element)` from deep inside the framework, naming
  /// neither the terminal nor the chat. Reusing the session keeps the element,
  /// the focus and the scroll position, and there is nothing left to race.
  ///
  /// The screen is cleared, scrollback included: what was above belonged to the
  /// program being replaced, and leaving it would read as one conversation.
  void relaunch({
    required ShellCommand command,
    required Map<String, String> environment,
    required void Function(Object error, StackTrace stack) onError,
  }) {
    _output?.cancel();
    _output = null;
    final pty = _pty;
    _pty = null;
    if (pty != null) _endTree(pty);
    _command = command;
    _environment = environment;
    // [start] refuses to run while one is running, and the shell it was told to
    // kill has not reported back yet.
    _shell = const ShellIdle();
    terminal.write('\x1b[H\x1b[2J\x1b[3J');
    start(onError: onError);
  }

  /// Ends the shell and everything it started, and releases the pty. The
  /// session is unusable afterwards.
  void dispose() {
    _output?.cancel();
    _output = null;
    final pty = _pty;
    _pty = null;
    if (pty != null) _endTree(pty);
    controller.dispose();
  }

  /// Kills the program in the pty **and its children**.
  ///
  /// SIGHUP on POSIX, not SIGTERM: it is what closing a terminal window sends,
  /// so a shell hangs up what it started (a running `flutter run`) on the way
  /// out rather than leaving it holding a pty nobody is reading.
  ///
  /// **Windows has no equivalent and `Pty.kill` does not pretend otherwise** —
  /// it is `Process.killPid`, which ends the one process it names. An agent CLI
  /// is a tree (ripgrep, MCP servers, whatever it shelled out to), and every one
  /// of those outlives the chat that opened it, still holding the folder and the
  /// ports the next session wants. `taskkill /F /T` is the tree-kill Windows
  /// does have. The same gap left orphaned engines behind in the CLI until
  /// `shared/run_records.py` grew the same call.
  void _endTree(Pty pty) {
    if (!Platform.isWindows) {
      pty.kill(ProcessSignal.sighup);
      return;
    }
    unawaited(
      Process.run('taskkill', ['/F', '/T', '/PID', '${pty.pid}']).catchError((
        Object _,
      ) {
        // No taskkill on this machine is not a reason to leave the CLI running:
        // one process ended is better than none.
        pty.kill();
        return ProcessResult(pty.pid, -1, '', '');
      }),
    );
  }

  void _onExit(Pty pty, int code) {
    // Not the program on screen any more: either we ended it, or a [relaunch]
    // has already put another one in its place. Compared by identity rather
    // than by "is there a pty at all" — the null check alone let a killed
    // program's exit code land on its successor and print "[Terminal closed]"
    // over a session that had just started.
    if (!identical(_pty, pty)) return;
    _shell = ShellExited(code: code);
    terminal.write(
      code == 0
          ? '\r\n[Terminal closed]\r\n'
          : '\r\n[Terminal closed · exit code $code]\r\n',
    );
    onChanged?.call();
  }

  /// [message] is the one line the panel shows; [line] is written onto the
  /// screen itself, where there is room to name the folder that was tried.
  void _fail({required String message, required String line}) {
    _shell = ShellFailed(message: message);
    terminal.write('\r\n$line\r\n');
  }
}
