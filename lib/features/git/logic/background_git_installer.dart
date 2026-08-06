import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/git_probe.dart';
import '../../../infrastructure/cli/git_providers.dart';
import '../../../infrastructure/logging/app_log.dart';
import 'git_install_controller.dart';

final backgroundGitInstallerProvider = Provider<BackgroundGitInstaller>(
  BackgroundGitInstaller.new,
);

/// Makes sure a Git the app can use exists, the moment the user is in.
///
/// Same shape and same manners as [BackgroundAgentInstaller]: it runs once, in
/// the background, and says nothing. Nobody is asked, nothing is blocked, and a
/// failure is a line in the log rather than a screen — a user who came here to
/// chat does not need Git to do it, and finding out about a download they didn't
/// ask for would be worse than the download itself. The reason a failure isn't
/// lost is that the install runs through [GitInstallController], so Settings ▸
/// Git still has it whenever the user goes looking.
///
/// **A Git the user already has always wins.** The app only fills a gap: if the
/// machine has a working Git, this adopts it and installs nothing. Git carries
/// the user's own credential helper, proxy and certificate settings, so
/// replacing theirs would break cloning private repositories in a way that would
/// look like our bug and be theirs to debug.
class BackgroundGitInstaller {
  BackgroundGitInstaller(this._ref);

  final Ref _ref;

  /// Guards a second run in the same session — the shell can fire this from more
  /// than one place, and an install downloads tens of MB.
  bool _attempted = false;

  Future<void> startIfNeeded() async {
    if (_attempted) return;
    // Claimed before the first await, so a second call can't start a second
    // download.
    _attempted = true;

    final log = _ref.read(appLogProvider);

    final found = await probeGit();
    switch (found) {
      case GitReady():
        adoptGit(found);
        log.info('git', 'Using ${found.version} at ${found.path}');
        return;
      case GitTooOld(:final version, :final path):
        // Old enough that the flows needing Git would fail inside git rather
        // than here. Ours goes in beside it; the log keeps the reason, because
        // from here on the user's own git is not the one being run.
        log.warn('git', 'Git at $path is too old ($version) — installing ours');
      case GitMissing():
        log.info('git', 'No Git on this computer — installing ours');
    }

    // Through the controller, not straight to the installer: it owns the
    // single-flight guard, the re-probe and the adopt, so a user who opens
    // Settings ▸ Git mid-download sees this install rather than starting a
    // second one into the same directory.
    await _ref.read(gitInstallProvider.notifier).install();
  }
}
