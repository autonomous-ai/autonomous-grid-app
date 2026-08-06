import 'dart:ffi' show Abi;
import 'dart:io';

import '../../core/grid_paths.dart';
import 'agent_download.dart';
import 'git_probe.dart';
import 'git_release_pins.dart';

/// Raised when Git couldn't be put on this computer. [retryable] is true for a
/// transient failure (a download, a proxy) where trying again might work, and
/// false for a machine this build has no Git for — the same split
/// `AgentInstallException` makes, so a caller can tell "try later" from "never".
class GitInstallException implements Exception {
  const GitInstallException(this.message, {this.retryable = false});

  final String message;
  final bool retryable;

  @override
  String toString() => 'GitInstallException: $message';
}

/// Puts a Git under `~/.grid` when the computer has none.
///
/// Behind an interface so the background installer can be tested against a fake
/// that downloads nothing — §8's "offline & deterministic" applies here more than
/// anywhere, since the real thing fetches 60 MB.
abstract interface class GitInstaller {
  /// Whether this build can install Git on this platform at all. False on
  /// Windows today, where the asset that carries a usable Git Bash needs a
  /// different unpack (see [gitBuildFor]).
  bool get supported;

  /// Download, verify and unpack Git, replacing any copy the app installed
  /// before. Throws [GitInstallException]; never touches a Git the user
  /// installed themselves.
  Future<void> install({void Function(String line)? onLog});
}

class GitInstallerImpl implements GitInstaller {
  const GitInstallerImpl();

  @override
  bool get supported => gitBuildFor(Abi.current()) != null;

  @override
  Future<void> install({void Function(String line)? onLog}) async {
    final build = gitBuildFor(Abi.current());
    if (build == null) {
      throw const GitInstallException(
        "This computer's platform has no pinned Git build.",
      );
    }

    final staging = await Directory.systemTemp.createTemp('grid-git-');
    try {
      onLog?.call('Downloading Git $kGitVersion …');
      final archive = await downloadToFile(Uri.parse(build.url), staging);
      // Nothing from the network runs before this passes.
      await verifySha256(archive, build.sha256);

      onLog?.call('Unpacking Git …');
      final unpacked = Directory('${staging.path}/unpacked');
      await extractArchive(archive, unpacked);

      await _swapIn(unpacked);
      await _verifyRuns();
      onLog?.call('Git $kGitVersion is ready.');
    } on AgentDownloadException catch (error) {
      throw GitInstallException(error.message, retryable: true);
    } on GitInstallException {
      rethrow;
    } on Object catch (error) {
      throw GitInstallException("Couldn't install Git: $error");
    } finally {
      await staging.delete(recursive: true);
    }
  }

  /// Replace `~/.grid/tools/git` with the freshly unpacked tree.
  ///
  /// The old copy is moved aside and deleted only once the new one is in place,
  /// so a failure here leaves the previous Git working rather than a half-tree
  /// that answers `--version` and nothing else.
  Future<void> _swapIn(Directory unpacked) async {
    final target = GridPaths.gitDir;
    await target.parent.create(recursive: true);
    final previous = Directory('${target.path}.old');
    if (await previous.exists()) await previous.delete(recursive: true);
    if (await target.exists()) await target.rename(previous.path);
    try {
      await unpacked.rename(target.path);
    } on FileSystemException {
      // A rename across filesystems (temp dir on another volume) fails; fall
      // back to a copy so the install still lands.
      await _copyTree(unpacked, target);
    }
    if (await previous.exists()) await previous.delete(recursive: true);
  }

  Future<void> _copyTree(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final entity in from.list(recursive: true)) {
      final relative = entity.path.substring(from.path.length + 1);
      final destination = '${to.path}/$relative';
      if (entity is Link) {
        await Link(destination).create(await entity.target());
      } else if (entity is File) {
        await Directory(destination).parent.create(recursive: true);
        await entity.copy(destination);
      } else if (entity is Directory) {
        await Directory(destination).create(recursive: true);
      }
    }
    if (!Platform.isWindows) {
      await Process.run('chmod', ['-R', 'u+rwX,go+rX', to.path]);
    }
  }

  /// Confirm the tree actually runs before calling the install a success —
  /// `HermesAcpSetup` verifies the same way rather than trusting an exit code,
  /// and here an archive that unpacked cleanly can still be missing the helper
  /// that HTTPS needs.
  Future<void> _verifyRuns() async {
    final status = await probeGit();
    if (status is GitReady && status.ours) return;
    throw const GitInstallException(
      'Git was unpacked but would not run on this computer.',
    );
  }
}
