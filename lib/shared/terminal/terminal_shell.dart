/// The program a terminal runs, and the arguments it starts with.
typedef ShellCommand = ({String executable, List<String> arguments});

/// Picks the shell a new terminal opens — the user's own, not the app's idea of
/// one, so the prompt, aliases and completions are the ones they already know.
///
/// Started as a **login** shell on macOS and Linux (`-l`), and that flag is the
/// whole reason this function exists rather than a literal at the call site. A
/// desktop app launched from Finder inherits a bare `PATH` (`/usr/bin:/bin:
/// /usr/sbin:/sbin`) — the one launchd hands it, not the one the user's terminal
/// has. Without `-l` the shell never reads `.zprofile`/`.bash_profile`, so
/// Homebrew, nvm, pyenv and `flutter` itself are all missing, and the terminal
/// answers `command not found` to the commands the chat beside it just suggested.
///
/// Windows takes no such flag: `cmd.exe` has no login-shell concept, and the
/// environment there is the machine's, not a shell profile's.
ShellCommand resolveShell({
  required Map<String, String> environment,
  required String operatingSystem,
}) {
  if (operatingSystem == 'windows') {
    return (
      executable: _nonEmpty(environment['COMSPEC']) ?? 'cmd.exe',
      arguments: const [],
    );
  }
  // `SHELL` is what the OS records as the account's shell; the fallbacks are
  // each platform's own default, for the account that somehow has none.
  final fallback = operatingSystem == 'macos' ? '/bin/zsh' : '/bin/bash';
  return (
    executable: _nonEmpty(environment['SHELL']) ?? fallback,
    arguments: const ['-l'],
  );
}

/// An environment variable that is set but empty is the same as unset here —
/// spawning `''` fails with a message about no such file.
String? _nonEmpty(String? value) =>
    value == null || value.isEmpty ? null : value;

/// [command] with every token quoted the way Windows' own parser reads it back.
///
/// **A pty on Windows takes a command line, not an argv.** `flutter_pty` builds
/// one by joining the executable and each argument with single spaces and
/// quoting nothing (`src/flutter_pty_win.c`, `build_command`), then hands it to
/// `CreateProcessW` with no application name — so the child's own parser splits
/// it again. Two things break in that round trip, and both fail the way §7 warns
/// a wrong flag does:
///
/// - A path with a space in it stops being one token. `C:\Program Files\...` is
///   read as `C:\Program`, and the session dies before the TUI draws.
/// - Codex's grid overrides lose the quotes TOML needs. `-c
///   approval_policy="on-request"` arrives as `approval_policy=on-request`,
///   which is not a TOML value at all.
///
/// POSIX never goes near this: there `flutter_pty` execs an argv array, so a
/// quote added here would be part of the argument. Hence the platform check at
/// the call site rather than inside.
ShellCommand quoteForWindowsPty(ShellCommand command) => (
  // The program name is not parsed by the same rules — `CreateProcessW` reads
  // everything up to the closing quote and does no backslash escaping, which is
  // exactly right for a path and exactly wrong for [windowsArgument].
  executable: _containsSpace(command.executable)
      ? '"${command.executable}"'
      : command.executable,
  arguments: command.arguments.map(windowsArgument).toList(),
);

/// One argument, encoded so `CommandLineToArgvW` hands the child back the string
/// that went in.
///
/// The rule the C runtime documents and every Windows program inherits: a run of
/// backslashes is literal, *unless* it precedes a quote — then it is doubled and
/// the quote is escaped. An argument with no space, tab or quote in it needs
/// none of this and is left alone, so the common case stays readable in a log.
String windowsArgument(String value) {
  if (value.isNotEmpty && !value.contains(_needsQuoting)) return value;
  final out = StringBuffer('"');
  var backslashes = 0;
  for (final unit in value.codeUnits) {
    if (unit == _backslash) {
      backslashes++;
      continue;
    }
    // Doubled before a quote, literal before anything else.
    out.write(_slash * (unit == _quote ? backslashes * 2 + 1 : backslashes));
    backslashes = 0;
    out.writeCharCode(unit);
  }
  // The closing quote is a quote too, so whatever trailed the value is doubled
  // as well — otherwise `C:\dir\` would escape the quote that ends it.
  out.write(_slash * (backslashes * 2));
  out.write('"');
  return out.toString();
}

/// A space, a tab or a quote — the three characters that stop an argument being
/// one token once Windows splits the command line again.
final _needsQuoting = RegExp('[ \t"]');

bool _containsSpace(String value) => value.contains(_needsQuoting);

const _backslash = 0x5C;
const _quote = 0x22;
final _slash = String.fromCharCode(_backslash);

/// The text a terminal types when files are dropped onto it: their paths, one
/// space apart, quoted only when a path has a space or a quote in it.
///
/// Deliberately not [windowsArgument]. That escapes for `CreateProcessW`, which
/// is a Windows kernel call; this is text going to whichever program is sitting
/// at the prompt — a shell, or an agent's CLI reading a line — and a
/// double-quoted string is the one rule all of them read the same way. A path
/// that needs no quotes keeps none, because a path the user can read back is
/// worth more than one that is uniformly escaped.
String droppedPathsLine(Iterable<String> paths) =>
    paths.map(droppedPath).join(' ');

/// One path, as [droppedPathsLine] writes it.
String droppedPath(String path) =>
    path.contains(_needsQuoting) ? '"${path.replaceAll('"', r'\"')}"' : path;

/// What a Windows pty actually has to be handed to run [command].
///
/// `flutter_pty` builds the Windows command line as `executable + ' ' + argv`,
/// and its own Dart side has already put the executable at `argv[0]` — the
/// POSIX convention, where `argv[0]` is the program's *name* rather than an
/// argument. Windows has no separate argv: the command line **is** the
/// arguments, so the program ends up named twice and the second copy reaches
/// the CLI as its first positional argument. Measured on the running app, from
/// `Win32_Process`:
///
///     claude.exe C:\Users\...\claude.exe --model "" --permission-mode ...
///
/// Claude Code reads a positional argument as the prompt to open with, so the
/// session fired a turn nobody typed — and the grid answered every retry with
/// `503 No providers available for this model`.
///
/// `cmd /c` is the way out, because it ignores the stray copy of its own name
/// and runs what follows: `cmd.exe cmd.exe /c <command>` runs `<command>`,
/// measured with `CreateProcessW` directly. Passing an empty executable to move
/// the whole line into the arguments does **not** work — a command line with a
/// leading space is rejected outright with `ERROR_INVALID_PARAMETER` (87).
///
/// The wrapper costs one process, which [ShellCommand]'s tree-kill already
/// accounts for, and `cmd /c` exits with the child's own code.
///
/// Known limit: `cmd` expands `%NAME%` while reading the line, and a `/c` line
/// has no way to escape a percent sign. A path holding one arrives changed.
ShellCommand windowsPtyCommand(
  ShellCommand command, {
  String shell = 'cmd.exe',
}) {
  final quoted = quoteForWindowsPty(command);
  final line = [
    quoted.executable,
    ...quoted.arguments,
  ].map(cmdSafeArgument).join(' ');
  // One pair of quotes around the whole line: with more than two quotes in it,
  // `cmd` strips the first and the last and runs exactly what was between them
  // (`cmd /?`, "old behavior"). Without the pair, a line that merely *ends* in a
  // quoted argument — Codex's `-c approval_policy="on-request"` — has that rule
  // applied to its own quotes instead, and the argument arrives cut in half.
  return (executable: shell, arguments: ['/c', '"$line"']);
}

/// [token], still one token after `cmd` has read the line.
///
/// A command line is read twice on this route: once by `cmd`, which acts on
/// `&`, `|`, `>` and their friends before the program is ever started, and once
/// by the program itself. Quotes are what turn those back into characters.
/// Anything [windowsArgument] already quoted needs nothing more.
String cmdSafeArgument(String token) =>
    token.startsWith('"') || !token.contains(_cmdMeta) ? token : '"$token"';

/// The characters `cmd` reads as punctuation rather than as text.
final _cmdMeta = RegExp(r'[&|<>^()!]');
