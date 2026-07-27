import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/grid_paths.dart';
import '../../core/host_arch.dart';
import 'agent_download.dart';
import 'agent_release_pins.dart';
import 'host_environment.dart';

/// How an agent gets onto this computer — the recipe the app runs instead of
/// `grid agent install`. Sealed so [AgentInstaller] handles every kind
/// exhaustively; each [AgentDefinition] returns the one that fits it.
sealed class AgentInstallSpec {
  const AgentInstallSpec();
}

/// Install a Python tool with `uv` (fetched and pinned first) into `~/.grid` —
/// how Hermes installs (`hermes-agent[acp]` on a private CPython).
class UvToolInstall extends AgentInstallSpec {
  const UvToolInstall({required this.package, required this.python});

  /// The uv requirement, extras included (e.g. `hermes-agent[acp]`).
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

/// Run a package-manager/script command to install the agent (e.g.
/// `npm i -g openclaw@latest`) — for an agent that ships no self-contained
/// binary. It lands wherever that tool puts globals, not `~/.grid/bin`.
class CommandInstall extends AgentInstallSpec {
  const CommandInstall(this.command);
  final List<String> command;
}

/// The argv for `uv tool install`. `--force` reinstalls in place, so install and
/// upgrade are the same call. Pure and unit-tested — a wrong flag fails exactly
/// like a package that wouldn't build.
List<String> uvToolInstallArgs({
  required String package,
  required String python,
}) => ['tool', 'install', '--force', '--python', python, package];

/// Why an install couldn't finish. [retryable] is true for a transient failure
/// (a download, a spawn) where sending again might work.
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
abstract interface class AgentInstaller {
  Future<void> run(
    AgentInstallSpec spec, {
    bool upgrade,
    void Function(String line)? onLog,
  });
}

/// Real installer: fetches (hash-verified) and runs, all inside `~/.grid`.
class AgentInstallerImpl implements AgentInstaller {
  const AgentInstallerImpl();

  @override
  Future<void> run(
    AgentInstallSpec spec, {
    bool upgrade = false,
    void Function(String line)? onLog,
  }) async {
    switch (spec) {
      case UvToolInstall(:final package, :final python):
        await _runUvTool(package, python, onLog);
      case GithubReleaseBinary():
        await _runReleaseBinary(spec, onLog);
      case CommandInstall(:final command):
        await _runCommand(command, onLog);
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
    final tmp = await Directory.systemTemp.createTemp('grid-agent-uv-');
    try {
      onLog?.call('Downloading uv …');
      final archive = await downloadToFile(Uri.parse(build.url), tmp);
      await verifySha256(archive, build.sha256);
      final extracted = Directory('${tmp.path}/extract');
      await extractArchive(archive, extracted);
      final found = locateBinary(extracted, uvName.toLowerCase());
      if (found == null) {
        throw const AgentInstallException('The uv archive had no uv binary.');
      }
      await GridPaths.binDir.create(recursive: true);
      return installBinary(found, uvBin);
    } finally {
      await tmp.delete(recursive: true);
    }
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
    final tmp = await Directory.systemTemp.createTemp('grid-agent-bin-');
    try {
      onLog?.call('Downloading ${spec.executable} …');
      final archive = await downloadToFile(Uri.parse(build.url), tmp);
      await verifySha256(archive, build.sha256);
      final extracted = Directory('${tmp.path}/extract');
      await extractArchive(archive, extracted);
      final found = locateBinary(extracted, spec.executable.toLowerCase());
      if (found == null) {
        throw AgentInstallException(
          'The ${spec.executable} archive had no ${spec.executable} binary.',
        );
      }
      final name = Platform.isWindows
          ? '${spec.executable}.exe'
          : spec.executable;
      await GridPaths.binDir.create(recursive: true);
      await installBinary(found, File('${GridPaths.binDir.path}/$name'));
    } finally {
      await tmp.delete(recursive: true);
    }
  }

  Future<void> _runCommand(
    List<String> command,
    void Function(String)? onLog,
  ) async {
    if (command.isEmpty) {
      throw const AgentInstallException('No install command was given.');
    }
    final env = {...Platform.environment, 'PATH': HostEnvironment.path()};
    onLog?.call('Running ${command.join(' ')} …');
    await _stream(command.first, command.sublist(1), env, onLog);
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

/// The installer used across the app. Overridden with a fake in tests.
final agentInstallerProvider = Provider<AgentInstaller>(
  (ref) => const AgentInstallerImpl(),
);
