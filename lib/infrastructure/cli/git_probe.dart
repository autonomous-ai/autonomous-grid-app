import 'dart:async';
import 'dart:io';

import '../../core/grid_paths.dart';
import 'git_release_pins.dart';
import 'host_environment.dart';

/// Where a usable Git was found, and which build it is.
sealed class GitStatus {
  const GitStatus();
}

/// A Git that ran and answered. [path] is absolute, and [ours] says whether it
/// is the copy under `~/.grid` — the installer uses that to leave a machine's
/// own Git alone.
class GitReady extends GitStatus {
  const GitReady({
    required this.path,
    required this.version,
    required this.ours,
  });

  final String path;
  final String version;
  final bool ours;
}

/// No Git this computer can run. Not the same as "no `git` file anywhere":
/// on macOS `/usr/bin/git` exists on every machine and is a stub.
class GitMissing extends GitStatus {
  const GitMissing();
}

/// A Git that runs but predates what the plugin flows need. Kept distinct from
/// [GitMissing] so the copy can say *upgrade* rather than *install*, and so the
/// installer doesn't silently shadow a Git the user is deliberately running.
class GitTooOld extends GitStatus {
  const GitTooOld({required this.path, required this.version});

  final String path;
  final String version;
}

/// How long a probe may take. A `git --version` answers in milliseconds; the
/// bound is here because a stub or a stalled network drive must not hang the
/// caller (`HermesAcpSetup` bounds its own check for the same reason).
const Duration kGitProbeTimeout = Duration(seconds: 5);

/// Find a Git this computer can actually run.
///
/// **On macOS this must never exec `/usr/bin/git`.** That file is present on
/// every Mac — it is one of 78 hard links to the same `xcode-select` stub, which
/// is why checking that it exists proves nothing. Running it when the Command
/// Line Tools are absent pops Apple's own installer dialog over whatever the
/// user was doing, so a *probe* would become an *install prompt*. The Mac branch
/// therefore resolves the developer directory first (with `xcode-select -p`, a
/// separate binary that never prompts) and runs the Git inside it by absolute
/// path.
///
/// Order is Grid's own copy first, then the machine's — so a freshly installed
/// copy is seen immediately, and [GitReady.ours] tells the caller which it got.
Future<GitStatus> probeGit() async {
  final ours = await _runnableGit(_ourGitPath());
  if (ours != null) return _classify(ours.path, ours.version, ours: true);

  final theirs = await _machineGit();
  if (theirs == null) return const GitMissing();
  return _classify(theirs.path, theirs.version, ours: false);
}

GitStatus _classify(String path, String version, {required bool ours}) {
  final parsed = parseGitVersion(version);
  if (parsed != null && !isSupportedGitVersion(parsed)) {
    return GitTooOld(path: path, version: version);
  }
  return GitReady(path: path, version: version, ours: ours);
}

/// The Git the app unpacked, whether or not it is there yet.
String _ourGitPath() {
  final exe = Platform.isWindows ? 'git.exe' : 'git';
  return '${GridPaths.gitDir.path}${Platform.pathSeparator}bin'
      '${Platform.pathSeparator}$exe';
}

/// The machine's own Git, per platform.
Future<({String path, String version})?> _machineGit() async {
  if (Platform.isMacOS) return _macGit();
  final found = HostEnvironment.findExecutable('git');
  if (found == null) return null;
  return _runnableGit(found);
}

/// macOS: resolve the active developer directory, then run the Git inside it by
/// absolute path. Both steps avoid `/usr/bin/git` entirely.
Future<({String path, String version})?> _macGit() async {
  // A Git installed outside the developer directory (Homebrew, MacPorts) is a
  // real answer and is safe to run — it is only the `/usr/bin` stubs that
  // prompt. Take it before falling back to Apple's.
  final onPath = HostEnvironment.findExecutable('git');
  if (onPath != null && !_isAppleStub(onPath)) {
    final ran = await _runnableGit(onPath);
    if (ran != null) return ran;
  }

  final developerDir = await _developerDir();
  if (developerDir == null) return null;
  final candidate = '$developerDir/usr/bin/git';
  return _runnableGit(candidate);
}

/// The stubs all live in `/usr/bin`; anything else is a real binary.
bool _isAppleStub(String path) {
  final resolved = _resolve(path);
  return resolved.startsWith('/usr/bin/');
}

String _resolve(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return path;
  }
}

/// The active developer directory: the `DEVELOPER_DIR` override if the user set
/// one, else what `xcode-select -p` reports. Null when there is none, or when it
/// names a directory that has since been removed — the stale-path case a macOS
/// upgrade leaves behind, where `-p` still answers but nothing is there.
Future<String?> _developerDir() async {
  final override = Platform.environment['DEVELOPER_DIR'];
  if (override != null && override.isNotEmpty) {
    return Directory(override).existsSync() ? override : null;
  }
  try {
    final result = await Process.run('/usr/bin/xcode-select', [
      '-p',
    ]).timeout(kGitProbeTimeout);
    if (result.exitCode != 0) return null;
    final path = (result.stdout as String).trim();
    if (path.isEmpty || !Directory(path).existsSync()) return null;
    return path;
  } on Object {
    return null;
  }
}

/// Run `<path> --version` and keep the answer only if it looks like Git's.
///
/// Exit code alone isn't enough: an App Execution Alias on Windows is a 0-byte
/// reparse point that `existsSync` reports as a file, and a stub can exit 0 while
/// printing something else entirely. The output has to say `git version`.
Future<({String path, String version})?> _runnableGit(String? path) async {
  if (path == null) return null;
  final file = File(path);
  if (!file.existsSync()) return null;
  // A zero-byte "executable" is a shim, not a program.
  try {
    if (file.lengthSync() == 0) return null;
  } on FileSystemException {
    return null;
  }

  try {
    final result = await Process.run(path, [
      '--version',
    ]).timeout(kGitProbeTimeout);
    if (result.exitCode != 0) return null;
    final out = (result.stdout as String).trim();
    if (!out.startsWith('git version')) return null;
    return (path: path, version: out);
  } on Object {
    return null;
  }
}

/// The `major.minor` in a `git version 2.53.0` line, or null when it doesn't
/// carry one — an unreadable version is treated as unknown rather than as old,
/// the same call `isSupportedGridVersion` makes for the CLI.
({int major, int minor})? parseGitVersion(String output) {
  final match = RegExp(r'(\d+)\.(\d+)').firstMatch(output);
  if (match == null) return null;
  final major = int.tryParse(match.group(1)!);
  final minor = int.tryParse(match.group(2)!);
  if (major == null || minor == null) return null;
  return (major: major, minor: minor);
}

/// The bare `2.53.0` out of a `git version 2.53.0` line, for a label that
/// already says "Git" — and for Apple's build, which appends `(Apple Git-154)`.
/// Falls back to the whole line when it carries no number: an odd label beats a
/// blank where a version should be.
String gitVersionLabel(String output) {
  final match = RegExp(r'\d+(\.\d+)+').firstMatch(output);
  return match?.group(0) ?? output.trim();
}

/// Whether [version] clears [kMinimumGitVersion].
bool isSupportedGitVersion(({int major, int minor}) version) {
  if (version.major != kMinimumGitVersion.major) {
    return version.major > kMinimumGitVersion.major;
  }
  return version.minor >= kMinimumGitVersion.minor;
}
