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
const String kHermesAcpRequirement = 'hermes-agent[acp]';

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
       _uv = uv ?? '${GridPaths.binDir.path}/uv',
       _gridHome = gridHome ?? GridPaths.home.path;

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
      env: hermesAcpRepairEnv(gridHome: _gridHome),
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
        environment: {
          ...HostEnvironment.hermesEnvironment(),
          ...env,
        },
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
