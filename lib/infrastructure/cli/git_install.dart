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
  ///
  /// Two callbacks because they have two different readers. [onStep] fires at
  /// each milestone — three lines, worth keeping in the log. [onProgress] fires
  /// many times a second as the archive lands and is for the screen only:
  /// logging it would bury the three lines that matter under sixty that don't.
  Future<void> install({
    void Function(String line)? onStep,
    void Function(String line)? onProgress,
  });
}

/// The line shown while the archive is arriving. Megabytes rather than a
/// percentage: on a stalled connection "38%" and "24 of 61 MB" say the same
/// thing, but only the second one tells the user how big the wait is.
///
/// Pure, so the wording is checked without a socket.
String downloadProgressLine(int received, int? total) {
  final got = _megabytes(received);
  if (total == null || total <= 0) {
    return 'Downloading Git $kGitVersion — $got MB';
  }
  return 'Downloading Git $kGitVersion — $got of ${_megabytes(total)} MB';
}

int _megabytes(int bytes) => (bytes / (1024 * 1024)).round();

class GitInstallerImpl implements GitInstaller {
  const GitInstallerImpl();

  @override
  bool get supported => gitBuildFor(Abi.current()) != null;

  @override
  Future<void> install({
    void Function(String line)? onStep,
    void Function(String line)? onProgress,
  }) async {
    final build = gitBuildFor(Abi.current());
    if (build == null) {
      throw const GitInstallException(
        "This computer's platform has no pinned Git build.",
      );
    }

    final staging = await _freshStaging();
    try {
      onStep?.call('Downloading Git $kGitVersion …');
      // Throttled to one line per whole megabyte. The callback fires per TCP
      // chunk — thousands of times — and a screen that rebuilt for each would
      // spend longer laying out than downloading.
      var lastMb = -1;
      final archive = await downloadToFile(
        Uri.parse(build.url),
        staging,
        onProgress: (received, total) {
          final mb = received ~/ (1024 * 1024);
          if (mb == lastMb) return;
          lastMb = mb;
          onProgress?.call(downloadProgressLine(received, total));
        },
      );
      // Nothing from the network runs before this passes.
      await verifySha256(archive, build.sha256);

      onStep?.call('Unpacking Git …');
      final unpacked = Directory('${staging.path}/unpacked');
      await extractArchive(archive, unpacked);

      await _swapIn(unpacked);
      await _verifyRuns();
      onStep?.call('Git $kGitVersion is ready.');
    } on AgentDownloadException catch (error) {
      throw GitInstallException(error.message, retryable: true);
    } on GitInstallException {
      rethrow;
    } on Object catch (error) {
      throw GitInstallException("Couldn't install Git: $error");
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  /// An empty staging tree *beside* the install target, not in the system temp
  /// directory.
  ///
  /// The point is the move at the end: a rename within one directory is atomic
  /// and cannot fail for being cross-device, so there is no window where
  /// `~/.grid/tools/git` holds a half-copied tree. That mattered — a copy killed
  /// after `bin/git` landed but before `libexec/` would leave a Git that answers
  /// `--version` perfectly and fails every clone, which the next launch would
  /// then adopt as working.
  ///
  /// A fixed name rather than a random one so an install killed mid-flight
  /// leaves at most one stale directory, which the next one clears. Safe because
  /// `GitInstallController` is the only caller and lets one install run at a
  /// time.
  Future<Directory> _freshStaging() async {
    final staging = Directory('${GridPaths.toolsDir.path}/.git-staging');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    return staging;
  }

  /// Replace `~/.grid/tools/git` with the freshly unpacked tree.
  ///
  /// The old copy is moved aside and deleted only once the new one is in place,
  /// so a failure here leaves the previous Git working rather than a half-tree
  /// that answers `--version` and nothing else.
  ///
  /// Both moves are renames inside one directory ([_freshStaging] is what makes
  /// that true), so each is atomic and there is no moment when the target holds
  /// a partial tree. Killing the app between the two leaves no Git at all, which
  /// the next launch probes and reinstalls — the recoverable failure, chosen
  /// over the one that leaves a Git that runs but can't clone.
  Future<void> _swapIn(Directory unpacked) async {
    final target = GridPaths.gitDir;
    await target.parent.create(recursive: true);
    final previous = Directory('${target.path}.old');
    if (await previous.exists()) await previous.delete(recursive: true);
    if (await target.exists()) await target.rename(previous.path);
    await unpacked.rename(target.path);
    if (await previous.exists()) await previous.delete(recursive: true);
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
