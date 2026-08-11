import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/grid_paths.dart';
import '../../core/host_arch.dart';
import 'agent_download.dart';
import 'agent_release_pins.dart';
import 'host_environment.dart';

/// How an agent gets onto this computer — the recipe the app runs itself.
///
/// Sealed so [AgentSpecInstaller] handles every kind exhaustively, and so adding
/// an agent means writing its recipe here rather than waiting on a `grid` build:
/// the CLI's `agent install` took a hardcoded whitelist of names, which is why
/// the app owns this now.
sealed class AgentInstallSpec {
  const AgentInstallSpec();
}

/// Install a Python tool with `uv` (fetched and pinned first) into `~/.grid` —
/// how Hermes installs, onto a private CPython.
class UvToolInstall extends AgentInstallSpec {
  const UvToolInstall({required this.package, required this.python});

  /// The uv requirement, extras included (e.g. `hermes-agent[acp,mcp]`).
  final String package;

  /// The CPython version uv pins for it (e.g. `3.13`).
  final String python;
}

/// Drop a prebuilt binary from a GitHub release into `~/.grid/bin` — how Codex
/// installs. [buildFor] resolves the pinned asset for a target triple, so a new
/// release-binary agent supplies its own pins without changing the installer.
class GithubReleaseBinary extends AgentInstallSpec {
  const GithubReleaseBinary({
    required this.executable,
    required this.buildFor,
    this.linuxMusl = false,
  });

  /// The on-disk executable name (bare; `.exe` is added on Windows).
  final String executable;

  /// The pinned build for a `<arch>-<os>` target, or null when none exists.
  final ReleaseBuild? Function(String target) buildFor;

  /// Whether this agent's Linux build is static musl (Codex) rather than gnu.
  final bool linuxMusl;
}

/// Install an npm package with a private, pinned Node into `~/.grid` — how Pi
/// installs. Pi ships only on npm, so the app fetches [nodeBuildFor]'s Node
/// toolchain (hash-verified), unpacks it under `~/.grid/node`, then runs its own
/// npm to install [package] with `--prefix ~/.grid` — the launcher lands in
/// `~/.grid/bin`, already first on the augmented PATH. The same self-contained
/// story as [UvToolInstall]: a private runtime under `~/.grid`, no system Node,
/// no admin, and a directory removal uninstalls it.
class NodeToolInstall extends AgentInstallSpec {
  const NodeToolInstall({required this.package, required this.executable});

  /// The npm package spec, version included (`@earendil-works/pi-coding-agent@0.84.1`).
  final String package;

  /// The launcher name npm writes into the prefix's bin (`pi`).
  final String executable;
}

/// The argv for `uv tool install`. `--force` reinstalls in place, so install and
/// upgrade are the same call; a repair passes `force: false` to keep the
/// environment that's already there ([hermesAcpRepairArgs]). Pure and
/// unit-tested — a wrong flag fails exactly like a package that wouldn't build.
List<String> uvToolInstallArgs({
  required String package,
  required String python,
  bool force = true,
}) => ['tool', 'install', if (force) '--force', '--python', python, package];

/// Why an install couldn't finish. [retryable] is true for a transient failure
/// (a download, a spawn) where trying again might work.
class AgentInstallException implements Exception {
  const AgentInstallException(this.message, {this.retryable = false});
  final String message;
  final bool retryable;

  @override
  String toString() => 'AgentInstallException: $message';
}

/// Installs an agent from its [AgentInstallSpec], streaming the tool's own
/// output to [onLog] so a slow first install shows life. Behind an interface so
/// controllers test against a fake without touching the network or the disk.
abstract interface class AgentSpecInstaller {
  Future<void> run(AgentInstallSpec spec, {void Function(String line)? onLog});
}

/// Real installer: fetches (hash-verified) and runs, all inside `~/.grid` — no
/// Homebrew, no admin rights, nothing outside the directory Grid owns.
class AgentSpecInstallerImpl implements AgentSpecInstaller {
  const AgentSpecInstallerImpl();

  @override
  Future<void> run(
    AgentInstallSpec spec, {
    void Function(String line)? onLog,
  }) async {
    switch (spec) {
      case UvToolInstall(:final package, :final python):
        await _runUvTool(package, python, onLog);
      case GithubReleaseBinary():
        await _runReleaseBinary(spec, onLog);
      case NodeToolInstall(:final package):
        await _runNodeTool(package, onLog);
    }
  }

  Future<void> _runUvTool(
    String package,
    String python,
    void Function(String)? onLog,
  ) async {
    final uv = await _ensureUv(onLog);
    final env = {
      ...Platform.environment,
      'PATH': HostEnvironment.path(),
      // Keep uv's tool tree and the CPython it downloads inside ~/.grid, so Grid
      // owns what Grid installed and removing ~/.grid removes it too.
      'UV_TOOL_BIN_DIR': GridPaths.binDir.path,
      'UV_TOOL_DIR': GridPaths.toolsDir.path,
      'UV_PYTHON_INSTALL_DIR': GridPaths.pythonDir.path,
    };
    onLog?.call('Installing $package (this downloads a private Python) …');
    await _stream(
      uv.path,
      uvToolInstallArgs(package: package, python: python),
      env,
      onLog,
    );
  }

  /// The pinned `uv`, downloading it on first use into `~/.grid/bin`. Idempotent.
  Future<File> _ensureUv(void Function(String)? onLog) async {
    final uvName = Platform.isWindows ? 'uv.exe' : 'uv';
    final uvBin = File('${GridPaths.binDir.path}/$uvName');
    if (await uvBin.exists()) return uvBin;

    final target = agentPlatformTarget(Abi.current(), linuxMusl: false);
    final build = target == null ? null : uvBuildFor(target);
    if (build == null) {
      throw const AgentInstallException(
        "This computer's platform has no uv build, so the agent can't be "
        'installed here.',
      );
    }
    onLog?.call('Downloading uv …');
    return _fetchInto(
      build,
      prefix: uvName.toLowerCase(),
      destination: uvBin,
      missing: 'The uv archive had no uv binary.',
    );
  }

  Future<void> _runReleaseBinary(
    GithubReleaseBinary spec,
    void Function(String)? onLog,
  ) async {
    final target = agentPlatformTarget(
      Abi.current(),
      linuxMusl: spec.linuxMusl,
    );
    final build = target == null ? null : spec.buildFor(target);
    if (build == null) {
      throw AgentInstallException(
        "This computer's platform has no ${spec.executable} build, so it can't "
        'be installed here.',
      );
    }
    final name = Platform.isWindows
        ? '${spec.executable}.exe'
        : spec.executable;
    onLog?.call('Downloading ${spec.executable} …');
    await _fetchInto(
      build,
      prefix: spec.executable.toLowerCase(),
      destination: File('${GridPaths.binDir.path}/$name'),
      missing:
          'The ${spec.executable} archive had no ${spec.executable} binary.',
    );
  }

  /// Fetch a private Node, then let its own npm install [package] into `~/.grid`.
  Future<void> _runNodeTool(
    String package,
    void Function(String)? onLog,
  ) async {
    final node = await _ensureNode(onLog);
    final npmCli = _npmCli(node);
    final gridHome = GridPaths.home.path;
    final env = {
      ...Platform.environment,
      // Node's own bin first, so anything npm shells out to finds the node it
      // shipped with, then the augmented PATH the rest of the app uses.
      'PATH': '${node.parent.path}$_pathSep${HostEnvironment.path()}',
      // Keep npm's global root and its cache inside ~/.grid — Grid owns what Grid
      // installed, and a directory removal uninstalls it. `--prefix` puts the
      // launcher in `~/.grid/bin`, already first on the app's PATH.
      'npm_config_prefix': gridHome,
      'npm_config_cache': '$gridHome/.npm-cache',
      'npm_config_update_notifier': 'false',
      'npm_config_fund': 'false',
      'npm_config_audit': 'false',
    };
    onLog?.call('Installing $package …');
    await _stream(
      node.path,
      [
        npmCli.path,
        'install',
        '-g',
        '--prefix',
        gridHome,
        // No package of ours runs an install script, and one that did would be
        // arbitrary code from npm running as the user, unasked, behind a
        // background install. Pi installs and runs fine without them.
        '--ignore-scripts',
        package,
      ],
      env,
      onLog,
    );
    // The launcher npm wrote is a JS file with a `#!/usr/bin/env node` shebang,
    // so node must be reachable on the PATH the app hands Pi at run time. Put a
    // copy of ours in `~/.grid/bin` (first on that PATH) so Pi runs without a
    // system Node.
    await _linkNodeIntoBin(node);
  }

  /// The pinned Node toolchain under `~/.grid/node`, downloaded on first use.
  /// Idempotent — returns the `node` executable inside it. Node ships a whole
  /// tree (npm, symlinks and all), so it is unpacked whole rather than through
  /// [_fetchInto]'s single-binary path.
  Future<File> _ensureNode(void Function(String)? onLog) async {
    final nodeRoot = Directory('${GridPaths.home.path}/node');
    final nodeBin = _nodeBinIn(nodeRoot);
    if (await nodeBin.exists()) return nodeBin;

    final target = agentPlatformTarget(Abi.current(), linuxMusl: false);
    final build = target == null ? null : nodeBuildFor(target);
    if (build == null) {
      throw const AgentInstallException(
        "This computer's platform has no Node build, so Pi can't be installed "
        'here.',
      );
    }
    onLog?.call('Downloading Node (Pi runs on it) …');
    // Unpack inside ~/.grid so the final move is a same-filesystem rename that
    // keeps Node's symlinks and executable bits intact (a cross-device copy
    // would not).
    final unpack = Directory('${GridPaths.home.path}/.node-unpack');
    final tmp = await Directory.systemTemp.createTemp('grid-node-');
    try {
      final archive = await downloadToFile(Uri.parse(build.url), tmp);
      await verifySha256(archive, build.sha256);
      if (await unpack.exists()) await unpack.delete(recursive: true);
      await extractArchive(archive, unpack);
      // Node archives hold a single `node-<release>-<slug>/` top-level folder.
      final tops = unpack.listSync().whereType<Directory>().toList();
      if (tops.isEmpty) {
        throw const AgentInstallException('The Node archive was empty.');
      }
      if (await nodeRoot.exists()) await nodeRoot.delete(recursive: true);
      await tops.first.rename(nodeRoot.path);
      return nodeBin;
    } finally {
      await tmp.delete(recursive: true);
      if (await unpack.exists()) await unpack.delete(recursive: true);
    }
  }

  /// The `node` executable inside a Node toolchain rooted at [root] — under
  /// `bin/` on POSIX, at the root on Windows.
  File _nodeBinIn(Directory root) => File(
    Platform.isWindows ? '${root.path}/node.exe' : '${root.path}/bin/node',
  );

  /// The `npm-cli.js` shipped with the Node at [nodeBin] — `lib/node_modules`
  /// on POSIX, `node_modules` on Windows.
  File _npmCli(File nodeBin) {
    final root = Platform.isWindows ? nodeBin.parent : nodeBin.parent.parent;
    for (final rel in const [
      'lib/node_modules/npm/bin/npm-cli.js',
      'node_modules/npm/bin/npm-cli.js',
    ]) {
      final cli = File('${root.path}/$rel');
      if (cli.existsSync()) return cli;
    }
    throw const AgentInstallException('The Node toolchain shipped no npm.');
  }

  /// Put the private `node` where the app's PATH finds it, so Pi's launcher
  /// shebang resolves without a system Node. A link (single copy, tracks a
  /// reinstall) with a real-copy fallback where links aren't available.
  ///
  /// TODO(BE): on Windows npm's `--prefix` writes the launcher to `~/.grid`
  /// itself, not `~/.grid/bin`, so Pi isn't on the augmented PATH there yet —
  /// wire the Windows launcher location before shipping Pi on Windows.
  Future<void> _linkNodeIntoBin(File node) async {
    await GridPaths.binDir.create(recursive: true);
    final name = Platform.isWindows ? 'node.exe' : 'node';
    final destPath = '${GridPaths.binDir.path}/$name';
    final existingLink = Link(destPath);
    if (await existingLink.exists()) {
      await existingLink.delete();
    } else if (await File(destPath).exists()) {
      await File(destPath).delete();
    }
    try {
      await Link(destPath).create(node.path);
    } on FileSystemException {
      await node.copy(destPath);
      if (!Platform.isWindows) await Process.run('chmod', ['0755', destPath]);
    }
  }

  static final String _pathSep = Platform.isWindows ? ';' : ':';

  /// Download [build], check it against its pinned hash, unpack it, and put the
  /// binary named [prefix] at [destination] — the whole path from a URL to
  /// something runnable, in one place because both kinds of install take it.
  ///
  /// The hash check is the wall between a network fetch and code this app then
  /// executes: nothing runs before it passes. [missing] names what wasn't in the
  /// archive, so a caller says which agent it was looking for.
  Future<File> _fetchInto(
    ReleaseBuild build, {
    required String prefix,
    required File destination,
    required String missing,
  }) async {
    final tmp = await Directory.systemTemp.createTemp('grid-agent-');
    try {
      final archive = await downloadToFile(Uri.parse(build.url), tmp);
      await verifySha256(archive, build.sha256);
      final extracted = Directory('${tmp.path}/extract');
      await extractArchive(archive, extracted);
      final found = locateBinary(extracted, prefix);
      if (found == null) throw AgentInstallException(missing);
      await GridPaths.binDir.create(recursive: true);
      return await installBinary(found, destination);
    } finally {
      await tmp.delete(recursive: true);
    }
  }

  /// Spawn [exe] with [args], stream its output to [onLog], and throw its last
  /// words on a non-zero exit or a failure to start.
  Future<void> _stream(
    String exe,
    List<String> args,
    Map<String, String> env,
    void Function(String)? onLog,
  ) async {
    final Process process;
    try {
      process = await Process.start(exe, args, environment: env);
    } on ProcessException catch (error) {
      throw AgentInstallException(
        "Couldn't start ${_basename(exe)}: ${error.message}",
        retryable: true,
      );
    }
    String? lastLine;
    void take(String line) {
      final trimmed = line.trimRight();
      if (trimmed.isEmpty) return;
      lastLine = trimmed;
      onLog?.call(trimmed);
    }

    final out = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(take);
    final err = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(take);
    final code = await process.exitCode;
    await out.cancel();
    await err.cancel();
    if (code != 0) {
      throw AgentInstallException(
        lastLine ?? '${_basename(exe)} exited with code $code',
      );
    }
  }

  static String _basename(String path) => path.split(RegExp(r'[/\\]')).last;
}

/// The recipe runner used across the app. Overridden with a fake in tests, which
/// therefore download nothing.
final agentSpecInstallerProvider = Provider<AgentSpecInstaller>(
  (ref) => const AgentSpecInstallerImpl(),
);
