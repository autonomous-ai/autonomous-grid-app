import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/host_shell_service.dart';
import '../../models/logic/engine_status.dart';
import 'codex_providers.dart';

/// State of the one-time "install Codex" flow behind Agent mode.
///
/// Codex installs via `brew install --cask codex`. Brew doesn't need `sudo`, but
/// a GUI app can't stream a Homebrew install reliably (and shouldn't run system
/// installers silently — see the no-auto-install rule), so we hand off to
/// Terminal and re-check on Continue, mirroring the built-in engine setup.
sealed class CodexSetupState {
  const CodexSetupState();
}

/// Nothing running yet — the initial state.
class CodexSetupIdle extends CodexSetupState {
  const CodexSetupIdle();
}

/// `brew install --cask codex` was opened in Terminal; waiting for the user to
/// finish and press Continue. [note] is an optional hint after a Continue that
/// didn't yet detect codex.
class CodexSetupInstalling extends CodexSetupState {
  const CodexSetupInstalling({this.note});
  final String? note;
}

/// Codex is installed and Agent mode can be turned on.
class CodexSetupDone extends CodexSetupState {
  const CodexSetupDone();
}

/// Setup can't proceed; [message] is user-facing and actionable.
class CodexSetupFailed extends CodexSetupState {
  const CodexSetupFailed(this.message);
  final String message;
}

final codexInstallControllerProvider =
    NotifierProvider<CodexInstallController, CodexSetupState>(
      CodexInstallController.new,
    );

/// Drives the Codex install: open `brew install --cask codex` in Terminal, then
/// re-check on Continue. Homebrew itself is a prerequisite the built-in engine
/// setup already owns; if it's missing we point the user there rather than
/// re-driving the Homebrew bootstrap here (kept in one place).
class CodexInstallController extends Notifier<CodexSetupState> {
  /// The cask install. `ripgrep` comes along as a dependency; brew handles it.
  static const _installCommand = 'brew install --cask codex';

  @override
  CodexSetupState build() => const CodexSetupIdle();

  /// Starts setup. Opens the cask install in Terminal when Homebrew is present;
  /// otherwise stops with guidance to install Homebrew first.
  Future<void> run() async {
    if (!ref.read(homebrewInstalledProvider)) {
      state = const CodexSetupFailed(
        'Homebrew is required first. Set up the built-in engine on the Engines '
        'tab (that installs Homebrew), or install it from brew.sh, then come '
        'back.',
      );
      return;
    }
    final opened = await ref
        .read(hostShellServiceProvider)
        .openTerminal(_installCommand);
    if (!opened) {
      state = const CodexSetupFailed(
        "Couldn't open Terminal. Run '$_installCommand' manually, then press "
        'Continue.',
      );
      return;
    }
    state = const CodexSetupInstalling();
  }

  /// Re-checks for codex after the Terminal install. Wired to "Continue".
  void continueSetup() {
    ref.invalidate(codexPathProvider);
    if (ref.read(codexInstalledProvider)) {
      state = const CodexSetupDone();
      return;
    }
    state = const CodexSetupInstalling(
      note:
          "Codex isn't detected yet. Finish the install in Terminal, then "
          'press Continue.',
    );
  }

  /// Re-opens the install in Terminal (e.g. the user closed the window).
  Future<void> reopenTerminal() =>
      ref.read(hostShellServiceProvider).openTerminal(_installCommand);
}
