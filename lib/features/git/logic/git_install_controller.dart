import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/git_install.dart';
import '../../../infrastructure/cli/git_probe.dart';
import '../../../infrastructure/cli/git_providers.dart';
import '../../../infrastructure/logging/app_log.dart';

/// Where the one Git install this app ever runs has got to.
sealed class GitInstallState {
  const GitInstallState();
}

class GitInstallIdle extends GitInstallState {
  const GitInstallIdle();
}

/// Fetching or looking right now. [step] is the installer's own last line, so a
/// 60 MB download reads as progress rather than as a frozen button.
class GitInstallRunning extends GitInstallState {
  const GitInstallRunning(this.step);
  final String step;
}

class GitInstallFailed extends GitInstallState {
  const GitInstallFailed(this.message);
  final String message;
}

/// A check or an install finished, and [status] is what Git looks like now.
///
/// The status rather than a finished sentence, because the screen has to say
/// different things about the same outcome: a re-check that found nothing
/// finished perfectly well and must not be announced as a success.
///
/// It exists at all because the probe answers in about ten milliseconds — well
/// under a frame — so on a computer whose Git hasn't changed, pressing the
/// button moves nothing on screen. Without an outcome it reads as a dead
/// control.
class GitInstallDone extends GitInstallState {
  const GitInstallDone(this.status);
  final GitStatus status;
}

final gitInstallProvider =
    NotifierProvider<GitInstallController, GitInstallState>(
      GitInstallController.new,
    );

/// The single path Git is ever installed by — the background pass at launch and
/// the Settings ▸ Git button both come through here.
///
/// One controller rather than two callers of [GitInstaller] because both write
/// the same tree under `~/.grid`: a manual Install pressed while the background
/// pass was still downloading would have raced it into a half-swapped directory.
/// Sharing the state also means the screen shows the background install as it
/// happens, and still has the reason on it if that install failed hours ago.
class GitInstallController extends Notifier<GitInstallState> {
  @override
  GitInstallState build() => const GitInstallIdle();

  /// Put Grid's own Git on this computer. Silent about a platform it has no
  /// build for: the screen offers the user's own command there instead, and the
  /// background pass must not leave an error on a screen over a machine that
  /// was never going to be served.
  Future<void> install() async {
    if (state is GitInstallRunning) return;

    final log = ref.read(appLogProvider);
    final installer = ref.read(gitInstallerProvider);
    if (!installer.supported) {
      log.info('git', 'No pinned Git build for this platform — leaving it be');
      return;
    }

    state = const GitInstallRunning('Downloading Git…');
    try {
      await installer.install(
        onLog: (line) {
          log.info('git', line);
          state = GitInstallRunning(line);
        },
      );
    } on GitInstallException catch (error) {
      // The raw failure is already in the log above the humanised one (§6).
      log.warn('git', "Couldn't install Git: ${error.message}");
      state = GitInstallFailed(error.message);
      return;
    }

    final status = await _reprobe();
    // The installer verifies the tree runs before returning, so anything but
    // ready here means it stopped running between then and now — a failure,
    // not an outcome to report.
    state = status is GitReady
        ? GitInstallDone(status)
        : const GitInstallFailed(
            'Git was installed but would not run on this computer.',
          );
  }

  /// Look again — for the user who installed Git themselves from the command
  /// the screen gave them. Without it they'd get the answer cached at launch,
  /// and the screen would keep saying "no Git" until the app was restarted.
  Future<void> recheck() async {
    if (state is GitInstallRunning) return;
    state = const GitInstallRunning('Looking for Git…');
    // Always an outcome, including "found the same Git as before" — see
    // [GitInstallDone]. A probe this fast leaves nothing else to see.
    state = GitInstallDone(await _reprobe());
  }

  /// Re-run the probe, point the spawn environment at whatever it found, and
  /// let every screen reading [gitStatusProvider] see the new answer.
  ///
  /// The probe spawns a process, so its answer is cached for the app's lifetime;
  /// without this an install stays invisible until a restart. `refresh` rather
  /// than `invalidate` then `read`: it forces the rebuild and hands back the new
  /// future, instead of leaving the order the two are applied in to chance.
  Future<GitStatus> _reprobe() async {
    final status = await ref.refresh(gitStatusProvider.future);
    if (status is GitReady) adoptGit(status);
    return status;
  }
}
