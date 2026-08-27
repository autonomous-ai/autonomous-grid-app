import 'dart:io';

import '../../core/agent_homes.dart';
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
  ///
  /// **Grid's own profile, not the user's root** (2026-08-21). Hermes reads
  /// everything profile-scoped from this path — `config.yaml`, `skills/`,
  /// provider config — and the app rewrites all three. Pointed at `~/.hermes`
  /// that meant installing Grid silently repinned the model, narrowed
  /// `toolsets:` to an allowlist and changed `approvals.mode` for every
  /// `hermes` the user ran themselves. See [AgentHomes] for what stays shared.
  static String get hermesHome => AgentHomes.hermesProfile(GridPaths.userHome);

  /// What **every** agent Grid spawns inherits: this process's environment with
  /// the augmented [path] over it, plus the grid the app is on
  /// ([relayUrlVar] / [relayTokenVar], from [adoptGrid]) — the pair the web
  /// scripts read to search through the grid instead of from the user's own
  /// machine.
  ///
  /// [environment] stands in for `Platform.environment`, for tests only: what
  /// this function does to an inherited value is most of its behaviour, and a
  /// test cannot set a variable on its own process.
  ///
  /// The app launches three different agents — Claude Code, Codex and Hermes —
  /// and each builds the rest of its child environment for itself, because the
  /// rest is genuinely per-agent. This is the part that is true of all three,
  /// and it is one function so that a variable every Grid agent needs is set
  /// once and no spawn path can omit it: a missing environment variable is not
  /// an error anywhere, so a variable added to two sites out of three takes the
  /// capability away from the third in silence, with nothing to alarm on. Same
  /// reason [hermesEnvironment] is one function rather than a line repeated in
  /// every service that launches `hermes`.
  ///
  /// Merged **under** each agent's own map, so a turn's own variables win.
  ///
  /// ⚠️ **TODO(BE): on Windows this drops the inherited map's
  /// case-insensitivity.** `Platform.environment` is a case-insensitive map
  /// there and an ordinary one everywhere else (dart:io's
  /// `_CaseInsensitiveStringMap`), and spreading it into a literal makes a
  /// plain case-sensitive copy that keeps the OS's own spelling — usually
  /// `Path`. `'PATH'` below is then a **second** key rather than an override,
  /// and which one the child resolves is not decided here; the same blind spot
  /// makes [claudeExecEnvironment]'s removal an exact-match one. Pre-existing:
  /// all three spawn sites spelled this the same way before they shared this
  /// function, and it is left alone here on purpose — this is a prefactor and
  /// must not move Windows behaviour. Masked so far because a Windows GUI app
  /// inherits a usable `PATH` anyway, which is the whole reason this class
  /// exists on macOS and Linux and not there.
  static Map<String, String> agentEnvironment({
    Map<String, String>? environment,
  }) {
    final env = {...(environment ?? Platform.environment), 'PATH': path()};
    // Grid's own two names, and only ever Grid's. Stripped first and then set
    // from [adoptGrid], so what an agent reads is the grid the app is on right
    // now — never one this process happened to inherit. That is not tidiness:
    // a stale `GRID_RELAY_TOKEN` in a developer's shell is a credential for
    // somebody else's grid, and a script that found it would post a person's
    // searches there. It is the same hazard [claudeExecEnvironment]'s
    // `dropEnvironment` exists for, one variable over.
    env.remove(relayUrlVar);
    env.remove(relayTokenVar);
    final url = _relayBaseUrl;
    final token = _relayToken;
    // Both or neither, always. A URL with no token is a script posting
    // unauthenticated and being refused; a token with no URL is nothing at all.
    // Half a pair is the shape that produces a confusing failure instead of the
    // clear "web search needs a grid" the scripts print when both are absent.
    if (url != null && url.isNotEmpty && token != null && token.isNotEmpty) {
      env[relayUrlVar] = url;
      env[relayTokenVar] = token;
    }
    return env;
  }

  /// Where an agent's scripts reach this grid, and what they present to it.
  ///
  /// The relay base (`…/relay/v1`) and the per-grid access token. The access
  /// token and not the session token, for two reasons that are both the
  /// relay's: it is the only credential the relay can verify — it holds no
  /// signing key, and a session token is HS256 — and it lives a year rather
  /// than a day, which suits a process that starts, runs one command and exits.
  static const String relayUrlVar = 'GRID_RELAY_URL';
  static const String relayTokenVar = 'GRID_RELAY_TOKEN';

  static String? _relayBaseUrl;
  static String? _relayToken;

  /// Tell every agent Grid spawns from now on which grid it is on.
  ///
  /// Called wherever the selected grid is resolved, with nulls when there is no
  /// grid — passing null is how the pair is *taken away*, and it has to be,
  /// because signing out or leaving a grid must not leave a live token in the
  /// environment of the next agent. Same shape as [adoptGridGit]: state the app
  /// learns once, read by a builder that cannot ask for it.
  ///
  /// ⚠️ Claude Code and Codex take a fresh environment every turn, so they
  /// follow a grid switch immediately. **The Hermes gateway does not** — it is
  /// long-lived and takes its environment at start, so it keeps the previous
  /// grid's token until it restarts. Known and accepted (public-repo ADR 0036
  /// D-e); the token still names a grid the person is a member of, so the worst
  /// case is a search attributed to the grid they just left.
  static void adoptGrid({String? relayBaseUrl, String? relayToken}) {
    _relayBaseUrl = relayBaseUrl;
    _relayToken = relayToken;
  }

  /// The grid the app is on right now, for the app's own web tools — the
  /// same pair the scripts read from [relayUrlVar] / [relayTokenVar], from the
  /// same source, so a tool call and a script can never answer on two grids.
  /// Null with no grid, by the same both-or-neither rule as above.
  static ({String baseUrl, String token})? get relay {
    final url = _relayBaseUrl;
    final token = _relayToken;
    if (url == null || url.isEmpty || token == null || token.isEmpty) {
      return null;
    }
    return (baseUrl: url, token: token);
  }

  /// The spawn environment for a Hermes process: [agentEnvironment], plus
  /// [hermesHome] and — on Windows — [gitBash]. Used by every service that
  /// launches `hermes`, so none can forget `HERMES_HOME` and read the wrong
  /// config directory.
  static Map<String, String> hermesEnvironment() {
    final env = {
      ...agentEnvironment(),
      'HERMES_HOME': hermesHome,
      ...gitEnvironment(),
    };
    // Fill it in, never override: a user who set this chose their own bash, and
    // Hermes probes ours anyway before trusting it.
    if (Platform.isWindows && (env[_gitBashVar] ?? '').isEmpty) {
      final bash = gitBash();
      if (bash != null) env[_gitBashVar] = bash;
    }
    return env;
  }

  /// Hermes's own escape hatch for "use this bash".
  static const _gitBashVar = 'HERMES_GIT_BASH_PATH';

  /// The `bin` of the Git the app unpacked, once it is the one in use — or null
  /// whenever this computer has a Git of its own.
  ///
  /// **Only ever set when the machine had no usable Git.** That is what makes it
  /// safe for [_buildPath] to put it first: Git carries the user's own
  /// configuration — their credential helper, `http.proxy`, `sslCAInfo` — and a
  /// copy of ours in front of theirs would take all of it away and break cloning
  /// a private repository. Ours is meant to fill a gap, never to win a contest.
  static String? _gridGitBin;

  /// Adopt (or drop) the Git the app installed, after a probe has decided which
  /// Git this computer will use. Clears everything derived from it — [path] is
  /// memoised, and [gitBash] is memoised behind a "already probed" flag that
  /// otherwise survives the install that was supposed to fix it.
  static void adoptGridGit(String? binDir) {
    _gridGitBin = binDir;
    _cachedPath = null;
    resetGitBash();
  }

  /// Forget the cached Git Bash lookup.
  ///
  /// [gitBash] answers once per session and remembers even a `null`, and
  /// [hermesEnvironment] — the environment behind every `hermes` spawn — reads
  /// it. Installing Git without calling this leaves every later spawn missing
  /// `HERMES_GIT_BASH_PATH`, so the install appears to have done nothing until
  /// the app is restarted.
  static void resetGitBash() {
    _cachedGitBash = null;
    _gitBashProbed = false;
  }

  /// The environment a spawned process needs to use the Git the app unpacked,
  /// or empty when this computer is using its own.
  ///
  /// The build is relocatable through its environment rather than in the binary:
  /// without `GIT_EXEC_PATH` it cannot find `git-remote-https`, and `git clone`
  /// over HTTPS dies with `'remote-https' is not a git command` — measured, not
  /// assumed. `GIT_CONFIG_SYSTEM` and `GIT_TEMPLATE_DIR` are set for the same
  /// reason: their defaults are compiled-in paths that don't exist here.
  static Map<String, String> gitEnvironment() {
    final bin = _gridGitBin;
    if (bin == null) return const {};
    final root = File(bin).parent.path;
    return {
      'GIT_EXEC_PATH': '$root/libexec/git-core',
      'GIT_CONFIG_SYSTEM': '$root/etc/gitconfig',
      'GIT_TEMPLATE_DIR': '$root/share/git-core/templates',
    };
  }

  /// The Git Bash Hermes should run terminal commands through on Windows, or
  /// null off Windows and when Git isn't installed.
  ///
  /// Hermes shells every command through bash. To find one it checks a fixed
  /// list of Git-for-Windows install dirs (`%ProgramFiles%\Git`,
  /// `%LOCALAPPDATA%\Programs\Git`, its own portable copy) and then falls back
  /// to `where bash` — which on any machine with the WSL feature enabled
  /// answers `C:\Windows\System32\bash.exe`, the WSL launcher. With no distro
  /// installed that stub fails *every* command ("WSL … execvpe /bin/bash
  /// failed"), and Hermes hands it back as a last resort rather than reporting
  /// that it found no usable shell. The agent then looks broken — each terminal
  /// step going red — when Git is in fact installed, just not where Hermes
  /// looked (a `D:\Tools\Git`, a scoop or winget prefix).
  ///
  /// We already resolve tools off the augmented [path], so point Hermes at the
  /// bash sitting beside the `git` the user actually has. It still probes the
  /// path we give it and keeps its own fallbacks if that one can't start.
  static String? gitBash() =>
      _gitBashProbed ? _cachedGitBash : (_cachedGitBash = _findGitBash());

  static String? _cachedGitBash;
  static bool _gitBashProbed = false;

  static String? _findGitBash() {
    _gitBashProbed = true;
    if (!Platform.isWindows) return null;
    final git = findExecutable('git');
    return git == null ? null : gitBashBeside(git);
  }

  /// The bash belonging to the Git install that owns [gitPath], or null when
  /// there isn't one. Git for Windows lays out `<root>\cmd\git.exe` and
  /// `<root>\bin\git.exe` beside `<root>\bin\bash.exe`, so both spellings of the
  /// launcher lead to the same shell.
  ///
  /// A `git` that resolves to something without that layout — a shim, a stub —
  /// gets no answer rather than a guessed one: a wrong bash fails exactly like
  /// the WSL stub this exists to avoid.
  static String? gitBashBeside(String gitPath) {
    final root = File(gitPath).parent.parent.path;
    final sep = Platform.pathSeparator;
    final bash = File('$root${sep}bin${sep}bash.exe');
    return bash.existsSync() ? bash.path : null;
  }

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

    // The Git the app unpacked, which is non-null only when this machine had
    // none of its own ([_gridGitBin]). It has to sit ahead of the system dirs
    // below rather than at the end: on macOS `/usr/bin/git` is always present as
    // a Command Line Tools stub, so a Git added after `/usr/bin` would never be
    // the one found.
    final gitBin = _gridGitBin;
    if (gitBin != null) add(gitBin);

    // `GridPaths.userHome`, not `$HOME`: a Windows GUI process has no `HOME` at
    // all, so reading it directly dropped `.local/bin` — where `grid` itself
    // lives — off the PATH the app hands its children.
    add('${GridPaths.userHome}/.local/bin'); // uv tool / pipx

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
    // Every Node that nvm manages, newest first — and *after* the login shell,
    // so a user who has chosen a version keeps it and this only fills a gap.
    //
    // Needed because `hermes --tui` is a Node bundle (≥20) while the rest of
    // Hermes is Python: the ACP lane runs perfectly on a machine where the TUI
    // cannot start at all. nvm's initialisation usually lives in `.zshrc`, which
    // `-lc` above does not source — it is a *login*, non-interactive shell — so
    // the probe finds Node only on the machines that happen to set it up in a
    // profile instead. Listing the versions directory covers the rest.
    for (final dir in _nvmBins()) {
      add(dir);
    }
    for (final dir in _split(Platform.environment['PATH'])) {
      add(dir);
    }
    return dirs.join(_sep);
  }

  /// `~/.nvm/versions/node/*/bin`, newest version first.
  ///
  /// Sorted by the version in the directory name rather than by mtime: a
  /// reinstall touches an old version's directory without making it the one the
  /// user wants, and "newest" here has to mean the highest version or the
  /// ordering is arbitrary. Best-effort — an unreadable or absent nvm is simply
  /// no directories, which is the state this exists to improve on.
  static List<String> _nvmBins() {
    if (Platform.isWindows) return const [];
    final root = Directory('${GridPaths.userHome}/.nvm/versions/node');
    if (!root.existsSync()) return const [];
    try {
      final versions =
          root
              .listSync()
              .whereType<Directory>()
              .map((d) => d.path.split(Platform.pathSeparator).last)
              .where((name) => name.startsWith('v'))
              .toList()
            ..sort((a, b) => _compareVersions(b, a));
      return [for (final v in versions) '${root.path}/$v/bin'];
    } on FileSystemException {
      return const [];
    }
  }

  /// Compares `v24.13.0`-shaped names numerically, so `v9` sorts below `v20`
  /// where a string comparison would put it on top.
  static int _compareVersions(String a, String b) {
    final left = _versionParts(a);
    final right = _versionParts(b);
    for (var i = 0; i < 3; i++) {
      final diff = (i < left.length ? left[i] : 0).compareTo(
        i < right.length ? right[i] : 0,
      );
      if (diff != 0) return diff;
    }
    return 0;
  }

  static List<int> _versionParts(String name) => [
    for (final part in name.substring(1).split('.'))
      int.tryParse(part.split('-').first) ?? 0,
  ];

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

/// The variables Claude Code puts in the environment of everything it starts,
/// to tell a child process which session it is already inside.
///
/// Measured, not guessed — read out of a `claude.exe` this app had started, on
/// a machine where the app itself had been launched from a Claude Code session:
/// `CLAUDE_CODE_CHILD_SESSION=1`, `CLAUDE_CODE_SESSION_ID` naming *that* other
/// session, and `CLAUDE_CODE_MESSAGING_SOCKET` / `..._TOKEN` addressing its
/// private pipe. The CLI in the chat read them and said so:
/// "Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION marker".
///
/// A chat starts a session of its own. Whichever session happened to start the
/// app is not it, and handing over that session's name and message pipe is a
/// worse thing than the lost transcript it announced.
///
/// Only identity and the pipe: variables that merely *configure* Claude Code
/// (a compaction window, a feature flag) are left where they are, because a
/// user is as likely to have exported those on purpose as to have inherited
/// them.
const Set<String> kInheritedAgentSessionEnv = {
  'CLAUDECODE',
  'CLAUDE_CODE_CHILD_SESSION',
  'CLAUDE_CODE_SESSION_ID',
  'CLAUDE_CODE_ENTRYPOINT',
  'CLAUDE_CODE_EXECPATH',
  'CLAUDE_CODE_MESSAGING_SOCKET',
  'CLAUDE_CODE_MESSAGING_TOKEN',
  'CLAUDE_AGENT_SDK_VERSION',
  'CLAUDE_PID',
};

/// [environment], with another agent session's identity taken back out of it.
///
/// See [kInheritedAgentSessionEnv] for what is dropped and what is not.
Map<String, String> withoutInheritedAgentSession(
  Map<String, String> environment,
) => {
  for (final entry in environment.entries)
    if (!kInheritedAgentSessionEnv.contains(entry.key)) entry.key: entry.value,
};
