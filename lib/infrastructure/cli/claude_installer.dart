import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'host_environment.dart';

/// Anthropic's own installer for Claude Code, which downloads the native build
/// into `~/.local/bin`.
///
/// No Homebrew and **no `sudo`**: it installs under the user's home, which is
/// what makes it safe for the app to run on a button press rather than handing
/// the user a terminal (see the note on unattended installs in
/// `EngineSetupController` — that flow needed a password, this one doesn't).
const String kClaudeInstallUrl = 'https://claude.ai/install.sh';

/// Puts Claude Code on this computer, or moves it to the latest build.
///
/// Behind an interface for the same reason the CLI service is: the install
/// controller is a unit test with a fake, never a real download.
abstract interface class ClaudeInstaller {
  /// Fetch and run the install. Returns null on success, else the last line the
  /// installer said — which is what the user is shown.
  ///
  /// [upgrade] is a different command, not a flag: once the binary is here it
  /// updates itself (`claude install stable`), and re-running the bootstrap
  /// script over a working install is both slower and a download nobody needs.
  Future<String?> install({required bool upgrade});
}

/// Real implementation: `claude install stable` when it's already here, else the
/// vendor's bootstrap script through `sh`.
class ClaudeInstallerImpl implements ClaudeInstaller {
  const ClaudeInstallerImpl();

  /// How long the install may take before it's abandoned. Generous — it pulls a
  /// platform build over the network — but bounded, so a stalled download ends
  /// in a message rather than a spinner nobody can stop.
  static const Duration timeout = Duration(minutes: 10);

  @override
  Future<String?> install({required bool upgrade}) async {
    final binary = HostEnvironment.findExecutable('claude');
    final (command, args) = upgrade && binary != null
        ? (binary, const ['install', 'stable'])
        : ('/bin/sh', ['-c', 'curl -fsSL $kClaudeInstallUrl | bash']);
    try {
      final result = await Process.run(
        command,
        args,
        // The bootstrap script writes to `~/.local/bin`, which the GUI's minimal
        // PATH doesn't carry — the same gap that once made the app claim
        // Homebrew was missing. HostEnvironment is what knows the real one.
        environment: {...Platform.environment, 'PATH': HostEnvironment.path()},
      ).timeout(timeout);
      if (result.exitCode == 0) return null;
      return _lastLine(result) ??
          'The installer stopped with code ${result.exitCode}.';
    } on ProcessException catch (error) {
      return error.message;
    } on Object {
      return 'The install took too long and was stopped.';
    }
  }

  /// The installer's own last words — stderr first, since that is where a failed
  /// download says why.
  static String? _lastLine(ProcessResult result) => [
    ...'${result.stderr}'.split('\n'),
    ...'${result.stdout}'.split('\n'),
  ].map((line) => line.trim()).where((line) => line.isNotEmpty).lastOrNull;
}

/// Wired through the container so the install controller gets it via `ref.read`,
/// and tests can hand it a fake that downloads nothing.
final claudeInstallerProvider = Provider<ClaudeInstaller>(
  (ref) => const ClaudeInstallerImpl(),
);
