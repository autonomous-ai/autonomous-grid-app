import 'dart:io';

import '../../core/grid_paths.dart';

/// The `PATH` (and spawn environment) a Finder/`open`-launched GUI app must use
/// to find user-installed command-line tools.
///
/// macOS/Linux GUI apps inherit only a minimal `PATH` (`/usr/bin:/bin:/usr/sbin:
/// /sbin`) — not the shell's. So tools the user clearly has (Homebrew at
/// `/usr/local/bin` on Intel or `/opt/homebrew/bin` on Apple Silicon, Docker,
/// cmake, `grid`'s own children) are invisible. The CLI then fails with bogus
/// "Homebrew is required" / "X not installed" errors, and our own `which` probes
/// (container engine detection) come back empty — even though everything is
/// installed. Run from `flutter run` it all works, because the terminal's `PATH`
/// is inherited; only the packaged app trips on this.
///
/// We rebuild `PATH` from four sources, de-duplicated, order-preserving:
///   1. `~/.grid/bin` — the tools Grid installs for itself (the built-in engine,
///      the chat agent). It comes first: a copy Grid installed and pinned beats
///      whatever else happens to be on the machine.
///   2. well-known tool dirs a GUI `PATH` usually omits (both Homebrew prefixes),
///   3. the user's real login-shell `PATH` (asdf/nvm/pyenv/custom installs),
///   4. the inherited `PATH` as a final fallback.
class HostEnvironment {
  HostEnvironment._();

  static String? _cachedPath;

  /// The augmented `PATH`, computed once per session (the login-shell probe
  /// spawns a process, so it's cached).
  static String path() => _cachedPath ??= _buildPath();

  /// The config/state directory Hermes must read and write (`<home>/.hermes`),
  /// i.e. exactly where [ClientAppConfigurator] writes Hermes's `config.yaml`
  /// and `.env` (the grid endpoint + access token).
  ///
  /// Hermes 0.19.0 changed its *default* config directory on **native Windows**
  /// to `%LOCALAPPDATA%\hermes`, while the app still writes Hermes's config to
  /// `<home>/.hermes`. Left to its default, Hermes on Windows then reads an empty
  /// config — no grid provider, no api key — falls back to a built-in provider,
  /// and every turn dies on a relay 401 ("Missing Authentication header") that
  /// the chat mislabels as "sign out and back in". Pointing `HERMES_HOME` at the
  /// directory the app actually wrote fixes it. Set on every platform (on POSIX
  /// it equals Hermes's own default, so it's a harmless no-op) so the two
  /// locations can never drift again.
  static String get hermesHome => '${GridPaths.userHome}/.hermes';

  /// The spawn environment for a Hermes process: the augmented [path] and
  /// [hermesHome], merged over the inherited environment. Used by every service
  /// that launches `hermes`, so none can forget `HERMES_HOME` and read the wrong
  /// config directory.
  static Map<String, String> hermesEnvironment() => {
    ...Platform.environment,
    'PATH': path(),
    'HERMES_HOME': hermesHome,
  };

  /// Absolute path to executable [name] on the augmented [path], or null when it
  /// isn't installed. Rebuilding `PATH` first means a packaged GUI app finds
  /// Homebrew / login-shell tools its minimal inherited `PATH` would miss.
  static String? findExecutable(String name) {
    final exe = Platform.isWindows ? '$name.exe' : name;
    for (final dir in path().split(_sep)) {
      if (dir.isEmpty) continue;
      final file = File('$dir${Platform.pathSeparator}$exe');
      if (file.existsSync()) return file.path;
    }
    return null;
  }

  static final String _sep = Platform.isWindows ? ';' : ':';

  static String _buildPath() {
    final dirs = <String>[];
    final seen = <String>{};
    void add(String dir) {
      final d = dir.trim();
      if (d.isEmpty || !seen.add(d)) return;
      dirs.add(d);
    }

    // Grid's own tools (llama-server, hermes) — installed by the CLI, so they
    // are found without Homebrew and without the user's shell.
    add(GridPaths.binDir.path);

    final home = Platform.environment['HOME'] ?? '';
    if (home.isNotEmpty) {
      add('$home/.local/bin'); // uv tool / pipx (where `grid` lives)
    }

    if (!Platform.isWindows) {
      // Both Homebrew prefixes plus the standard system dirs — the set a GUI
      // PATH most often lacks. Listed explicitly so detection works even if the
      // login-shell probe below fails.
      const wellKnown = [
        '/opt/homebrew/bin', '/opt/homebrew/sbin', // Apple Silicon Homebrew
        '/usr/local/bin', '/usr/local/sbin', // Intel Homebrew + many tools
        '/usr/bin', '/bin', '/usr/sbin', '/sbin',
      ];
      for (final dir in wellKnown) {
        add(dir);
      }
    }

    for (final dir in _loginShellPath()) {
      add(dir);
    }
    for (final dir in _split(Platform.environment['PATH'])) {
      add(dir);
    }
    return dirs.join(_sep);
  }

  /// The user's `PATH` as their login shell sees it (profile loaded). `-lc`
  /// (login, non-interactive) mirrors [GridResolver] and avoids interactive
  /// hangs. Best-effort: empty on any failure.
  static List<String> _loginShellPath() {
    if (Platform.isWindows) return const [];
    final shell = Platform.environment['SHELL'] ?? '/bin/zsh';
    try {
      final result = Process.runSync(shell, ['-lc', r'printf %s "$PATH"']);
      if (result.exitCode != 0) return const [];
      // Take the last non-empty line so any profile banner output is ignored.
      final lines = (result.stdout as String)
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      return lines.isEmpty ? const [] : _split(lines.last);
    } on ProcessException {
      return const [];
    }
  }

  static List<String> _split(String? path) =>
      (path == null || path.isEmpty) ? const [] : path.split(_sep);
}
