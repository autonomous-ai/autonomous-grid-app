import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

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
    this.command,
    this.environment = const {},
    this.onChanged,
  });

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
  final ShellCommand? command;

  /// Variables layered over the app's own for this session — the grid a chat
  /// answers on, and the key to reach it. Empty for a plain shell.
  ///
  /// Applied *under* `TERM`, so a caller cannot accidentally hand the program a
  /// terminal type that turns off colour and the cursor.
  final Map<String, String> environment;

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
        this.command ??
        resolveShell(
          environment: Platform.environment,
          operatingSystem: Platform.operatingSystem,
        );
    try {
      final pty = Pty.start(
        command.executable,
        arguments: command.arguments,
        workingDirectory: workdir,
        // The app's own environment, then this session's, plus the two variables
        // that decide whether the program believes it has a terminal at all.
        // `flutter_pty` sets both, but only for the variables it copies itself —
        // spreading ours over the top would otherwise hand the program whatever
        // `TERM` the app inherited (`dumb`, when launched from an IDE), and a
        // `dumb` terminal turns off colour, the cursor and every full-screen
        // program. Which is to say: the whole agent TUI.
        environment: {
          ...Platform.environment,
          ...environment,
          'TERM': 'xterm-256color',
          'TERM_PROGRAM': 'Grid',
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

      unawaited(pty.exitCode.then(_onExit));

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

  /// Types [text] into the program as if the user had typed it, then sends the
  /// Return that submits it.
  ///
  /// **The Return goes in a write of its own, a beat later, and that is not
  /// tidiness.** Sent in the same burst an agent's TUI reads the pair as a
  /// paste: measured against `codex-cli 0.144.6` on 2026-08-24, `"say only the
  /// word PONG\r"` in one write landed in the composer as a newline and the turn
  /// never started, while the same text followed by a separate `\r` submitted
  /// and was answered. Claude Code's TUI takes either, so both lanes send the
  /// pair the way the stricter one needs.
  ///
  /// Does nothing when no program is running — there is nobody to type at.
  Future<void> type(String text) async {
    final pty = _pty;
    if (pty == null || _shell is! ShellRunning) return;
    final encode = const Utf8Encoder().convert;
    pty.write(encode(text));
    await Future<void>.delayed(_submitGap);
    if (_pty == null) return;
    pty.write(encode('\r'));
  }

  /// The beat between the text and the Return that submits it — long enough
  /// that a TUI has read the first write and left paste mode, short enough that
  /// nobody sees it.
  static const _submitGap = Duration(milliseconds: 40);

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

  /// Ends the shell and releases the pty. The session is unusable afterwards.
  void dispose() {
    _output?.cancel();
    _output = null;
    // SIGHUP, not SIGTERM: it is what closing a terminal window sends, so a
    // shell hangs up its children (a running `flutter run`) on the way out
    // rather than leaving them holding a pty nobody is reading. Windows knows
    // only SIGTERM and SIGKILL — asking it for anything else throws.
    _pty?.kill(
      Platform.isWindows ? ProcessSignal.sigterm : ProcessSignal.sighup,
    );
    _pty = null;
    controller.dispose();
  }

  void _onExit(int code) {
    // Nothing to say if we're the ones who ended it.
    if (_pty == null) return;
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
