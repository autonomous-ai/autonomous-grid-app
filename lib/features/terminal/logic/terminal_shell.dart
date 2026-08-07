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
