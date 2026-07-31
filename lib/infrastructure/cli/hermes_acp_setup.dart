import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/grid_paths.dart';
import '../logging/app_log.dart';
import 'hermes_acp_service.dart';
import 'host_environment.dart';

/// What Hermes must be installed as before it can serve ACP — the only channel
/// the app talks to the agent through.
///
/// The `[acp]` extra pulls `agent-client-protocol`, which Hermes's ACP adapter
/// imports on startup. Installed without it, `hermes` is on the machine and
/// looks healthy while `hermes acp` dies immediately, so every chat turn fails
/// on what reads as a successful install. Older `grid` builds installed exactly
/// that, and those machines are still out there — hence [HermesAcpSetup].
///
/// `[mcp]` is here for the same reason one level quieter: it pulls the MCP SDK
/// every `mcp_servers:` entry needs, and Hermes imports that one inside a
/// `try/except`. Without it the agent starts fine, `acp --check` passes, and
/// every connector the app wrote into the config — Gmail, GitHub, a hand-added
/// server — is dropped without a word.
///
/// This is what the app installs Hermes with ([AgentTool.installSpec]) as well
/// as what it repairs with, so the two can't drift apart.
///
/// TODO(BE): the CLI's own installer (`autonomous-grid →
/// shared/agent/installer.py`) still asks for `hermes-agent[acp]` alone. The app
/// no longer goes through it, but a `grid agent install` run from a terminal
/// rebuilds the environment without the SDK, and the connectors stay dead until
/// [HermesAcpSetup.ensureRuntimeSupport] next runs.
const String kHermesAcpRequirement = 'hermes-agent[acp,mcp]';

/// The interpreter Hermes is pinned to (`>=3.11,<3.14`), matching the CLI's own
/// installer so a repair lands in the same private environment rather than
/// building a second one beside it.
const String kHermesPython = '3.13';

/// `uv` argv that adds the missing piece to the existing install.
///
/// Deliberately **not** `--force`: uv keeps the environment and installs only
/// what the changed extra adds (one small package), where a forced reinstall
/// would tear down and refetch the private CPython for no gain.
List<String> hermesAcpRepairArgs() => const [
  'tool',
  'install',
  '--python',
  kHermesPython,
  kHermesAcpRequirement,
];

/// The environment that keeps uv's tool tree — and the CPython it downloads —
/// inside `~/.grid`, exactly where the CLI's installer puts them. Without these
/// a repair would install a *second* Hermes under the user's home, and the one
/// on `PATH` would stay broken.
Map<String, String> hermesAcpRepairEnv({required String gridHome}) => {
  'UV_TOOL_BIN_DIR': '$gridHome/bin',
  'UV_TOOL_DIR': '$gridHome/tools',
  'UV_PYTHON_INSTALL_DIR': '$gridHome/python',
};

/// The uv tool-tree environment for repairing the Hermes at [hermesPath].
///
/// The `~/.grid` overrides are right only when *that* is where the Hermes we're
/// fixing lives ([hermesAcpRepairEnv] explains why). A Hermes installed by an
/// older uv-tool layout sits under the user's home instead; forcing ~/.grid then
/// builds a **second** Hermes there and leaves the one on `PATH` just as broken.
/// So off-`~/.grid`, hand uv no overrides and let its own defaults land on the
/// install that's actually failing.
Map<String, String> hermesAcpRepairEnvFor({
  required String hermesPath,
  required String gridHome,
}) => hermesPath.startsWith('$gridHome/')
    ? hermesAcpRepairEnv(gridHome: gridHome)
    : const {};

/// Where an installed `uv` might live, most-preferred first: the copy the CLI
/// drops in `~/.grid`, then the uv-tool default and the two Homebrew prefixes
/// (`/usr/local` is Intel's). A legacy Hermes was often set up by a `uv` that
/// never landed in `~/.grid/bin` — looking only there is why the self-repair
/// gave up on exactly the machines it exists to fix.
List<String> uvCandidatePaths({
  required String gridHome,
  required String home,
}) => [
  '$gridHome/bin/uv',
  if (home.isNotEmpty) '$home/.local/bin/uv',
  '/opt/homebrew/bin/uv',
  '/usr/local/bin/uv',
];

/// What Hermes imports lazily but its install doesn't bring — Python module name
/// to the requirement that provides it.
///
/// Both are optional imports inside a `try/except`, which is what makes them
/// worth a constant: the feature behind a missing one doesn't fail, it silently
/// isn't there.
/// - `ddgs` is the only keyless backend Hermes's native `web_search` can pick
///   (`tavily/exa/…` all want a key), so without it "search the news" has
///   nothing to run.
/// - `mcp` is the SDK behind every `mcp_servers:` entry. `hermes-agent` pins it
///   under its own `[mcp]` extra ([kHermesAcpRequirement]); the constraint here
///   is deliberately looser so topping up an existing environment can never
///   *downgrade* the SDK a newer Hermes installed for itself.
const Map<String, String> kHermesRuntimePackages = {
  'ddgs': 'ddgs',
  'mcp': 'mcp>=1.26,<2',
};

/// Python argv that prints the [kHermesRuntimePackages] modules [venvPython]
/// can't import, one per line — the question "what is actually missing", asked
/// of the interpreter Hermes runs on rather than guessed from its install
/// receipt. Import-free (`find_spec`), so probing costs nothing and can run
/// before every chat.
List<String> hermesRuntimeProbeArgs(Iterable<String> modules) => [
  '-c',
  'import importlib.util as u;'
      "print('\\n'.join(m for m in ${jsonEncode(modules.toList())} "
      'if u.find_spec(m) is None))',
];

/// The requirements to install for the modules [probeOutput] reported missing.
///
/// Anything the probe printed that isn't a module we asked about is ignored —
/// a stray line from the interpreter must never turn into a package name handed
/// to `uv`.
List<String> hermesMissingRequirements(String probeOutput) => [
  for (final line in const LineSplitter().convert(probeOutput))
    ?kHermesRuntimePackages[line.trim()],
];

/// `uv` argv that adds [requirements] to the environment [venvPython] belongs to
/// — Hermes's own venv. `pip install`, not `tool install`: this tops up the
/// environment in place, where re-running the tool install would re-resolve
/// Hermes itself and could move it to a build the user never asked for.
List<String> hermesRuntimeInstallArgs(
  String venvPython,
  List<String> requirements,
) => ['pip', 'install', '--python', venvPython, ...requirements];

/// Whether [raw] — an agent's dying words — says its install is missing a piece,
/// rather than that it failed for some other reason.
///
/// The shape of it is Hermes's own "ACP dependencies not installed. Install them
/// with: pip install -e '.[acp]'", plus the Python import errors a partial
/// install produces. Shared by the repair (what to fix) and the message shown
/// to the user (what to say), so the two can never disagree about which failure
/// this is.
bool isAcpSetupIncomplete(String raw) {
  final said = raw.toLowerCase();
  return (said.contains('acp') || said.contains('dependenc')) &&
          (said.contains('not installed') || said.contains('pip install')) ||
      said.contains('no module named') ||
      said.contains('modulenotfound');
}

/// Reads and repairs the *installed* state of Hermes's ACP support on this
/// computer — the half of "is the agent usable" that a binary on disk doesn't
/// answer.
abstract interface class HermesAcpSetup {
  /// Whether `hermes acp` can actually run here. Hermes answers this itself
  /// (`acp --check` runs the adapter's imports), so we never guess from the
  /// contents of its environment.
  Future<bool> isReady();

  /// Install the missing piece. Returns null once ACP really works, else the raw
  /// reason it still doesn't — for the log; callers humanize it (§6).
  Future<String?> repair();

  /// Best-effort: top the environment up with the [kHermesRuntimePackages]
  /// Hermes can't import here, so its web search has a backend and its MCP
  /// servers can actually be reached.
  ///
  /// Never throws and returns nothing — nothing the user is waiting on may hang
  /// behind an install, and a failure only leaves the agent as capable as it was
  /// (web search falls back on the `grid-web` skill). The reason is logged (§6),
  /// because a tool that silently isn't offered is otherwise invisible.
  Future<void> ensureRuntimeSupport();
}

/// Real [HermesAcpSetup], driving the pinned `uv` the CLI installed into
/// `~/.grid/bin`. Nothing here needs Homebrew, admin rights, or the user's
/// shell — the same constraints the CLI's installer works under.
class HermesAcpSetupImpl implements HermesAcpSetup {
  HermesAcpSetupImpl(
    this._hermes, {
    AppLog log = const NoopAppLog(),
    String? uv,
    String? gridHome,
  }) : _log = log,
       _gridHome = gridHome ?? GridPaths.home.path,
       _uv = uv ?? _resolveUv(gridHome ?? GridPaths.home.path);

  /// The first `uv` that actually exists among [uvCandidatePaths], or the
  /// `~/.grid` copy when none do — so a machine with no uv still gets the honest
  /// "installer (uv) is not on this computer" message rather than a random path.
  static String _resolveUv(String gridHome) {
    final candidates = uvCandidatePaths(
      gridHome: gridHome,
      home: Platform.environment['HOME'] ?? '',
    );
    return candidates.firstWhere(
      (path) => File(path).existsSync(),
      orElse: () => candidates.first,
    );
  }

  final String _hermes;
  final String _uv;
  final String _gridHome;
  final AppLog _log;

  /// An import check, so a machine that needs longer than this is wedged rather
  /// than slow.
  static const _checkTimeout = Duration(seconds: 30);

  /// A resolve plus one small package on a working install; the ceiling is for a
  /// slow connection, not for a hung download to sit behind forever.
  static const _repairTimeout = Duration(minutes: 5);

  @override
  Future<bool> isReady() async {
    final ran = await _run(_hermes, const ['acp', '--check'], _checkTimeout);
    return ran.code == 0;
  }

  @override
  Future<String?> repair() async {
    if (!File(_uv).existsSync()) {
      return "Grid's installer (uv) is not on this computer: $_uv";
    }
    _log.info('agent', 'Completing the Hermes install: $kHermesAcpRequirement');

    final ran = await _run(
      _uv,
      hermesAcpRepairArgs(),
      _repairTimeout,
      env: hermesAcpRepairEnvFor(hermesPath: _hermes, gridHome: _gridHome),
    );
    if (ran.code != 0) {
      _log.failure(
        'agent',
        'Hermes ACP repair failed (${ran.code})\n${ran.output}',
      );
      return ran.output.trim().isEmpty
          ? 'uv exited with ${ran.code}'
          : ran.output.trim();
    }

    // uv succeeding is not the claim that matters — Hermes running ACP is. A
    // repair that reports success while `hermes acp` still dies would send the
    // caller straight back into the failure it just tried to fix.
    if (await isReady()) {
      _log.info('agent', 'Hermes ACP support installed.');
      return null;
    }
    _log.failure('agent', 'Hermes still cannot serve ACP after a repair.');
    return 'hermes acp still fails after installing $kHermesAcpRequirement';
  }

  @override
  Future<void> ensureRuntimeSupport() async {
    final venvPython = _venvPython();
    if (!File(_uv).existsSync() || venvPython == null) return;

    final missing = await _missingRuntimeRequirements(venvPython);
    if (missing.isEmpty) return;

    final ran = await _run(
      _uv,
      hermesRuntimeInstallArgs(venvPython, missing),
      _repairTimeout,
      env: hermesAcpRepairEnvFor(hermesPath: _hermes, gridHome: _gridHome),
    );
    if (ran.code != 0) {
      _log.warn(
        'agent',
        'Could not add ${missing.join(', ')} to Hermes '
            '(${ran.code})\n${ran.output}',
      );
      return;
    }
    _log.info('agent', 'Completed the Hermes install: ${missing.join(', ')}');
  }

  /// What [kHermesRuntimePackages] Hermes can't import, asked of its own
  /// interpreter. A probe that couldn't run answers nothing, so it reports
  /// nothing missing: installing on a guess would re-resolve packages before
  /// every chat, on machines where there is nothing to fix.
  Future<List<String>> _missingRuntimeRequirements(String venvPython) async {
    final probed = await _run(
      venvPython,
      hermesRuntimeProbeArgs(kHermesRuntimePackages.keys),
      _checkTimeout,
    );
    if (probed.code == 0) return hermesMissingRequirements(probed.output);
    _log.warn(
      'agent',
      "Couldn't check what Hermes is missing (${probed.code})\n"
          '${probed.output}',
    );
    return const [];
  }

  /// The interpreter beside the hermes binary (`.../bin/hermes` → `.../bin/python`
  /// on macOS/Linux, `.../Scripts/python.exe` on Windows), or null when the
  /// layout isn't the one the CLI's uv install produces — then there's nothing
  /// safe to install into.
  String? _venvPython() {
    final bin = File(_hermes).parent.path;
    for (final candidate in [
      '$bin/python',
      '$bin/python3',
      '$bin/python.exe',
    ]) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// Run [exe] to completion, collecting both streams, and kill it if it
  /// outstays [timeout] — an install that hangs must not hang the chat behind
  /// it forever.
  Future<({int code, String output})> _run(
    String exe,
    List<String> args,
    Duration timeout, {
    Map<String, String> env = const {},
  }) async {
    final Process process;
    try {
      process = await Process.start(
        exe,
        args,
        environment: {...HostEnvironment.hermesEnvironment(), ...env},
      );
    } on ProcessException catch (e) {
      return (code: -1, output: e.message);
    }

    final output = StringBuffer();
    final drained = Future.wait([
      process.stdout.transform(utf8.decoder).forEach(output.write),
      process.stderr.transform(utf8.decoder).forEach(output.write),
    ]);
    var timedOut = false;
    final code = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        timedOut = true;
        process.kill();
        return -1;
      },
    );
    await drained;
    if (timedOut) output.write('\nTimed out after ${timeout.inSeconds}s.');
    return (code: code, output: output.toString());
  }
}

/// A [HermesAcpService] that completes a half-finished install instead of
/// handing the failure on.
///
/// The failure it fixes is not the user's doing and not something they can act
/// on: `grid` installed Hermes without the piece ACP needs, so the agent is
/// there and mute. Telling them to reinstall sent them round a loop that could
/// not end (the installer repeated the same install), so the app finishes the
/// job itself and retries the session — once. A second failure is a real one and
/// travels on to be shown.
class RepairingHermesAcpService implements HermesAcpService {
  const RepairingHermesAcpService(
    this._inner,
    this._setup, {
    AppLog log = const NoopAppLog(),
  }) : _log = log;

  final HermesAcpService _inner;
  final HermesAcpSetup _setup;
  final AppLog _log;

  @override
  Future<HermesAcpSession> start({required String workdir}) async {
    try {
      return await _inner.start(workdir: workdir);
    } on HermesAcpException catch (e) {
      if (!isAcpSetupIncomplete(e.message)) rethrow;
      _log.warn('agent', 'Hermes is missing its ACP support; repairing it.');

      final failure = await _setup.repair();
      if (failure != null) {
        throw HermesAcpException(
          '${e.message} — repair failed: $failure',
          retryable: false,
        );
      }
      return _inner.start(workdir: workdir);
    }
  }
}
