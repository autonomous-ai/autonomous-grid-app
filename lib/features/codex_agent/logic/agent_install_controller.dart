import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/host_shell_service.dart';
import '../../models/logic/engine_status.dart';
import 'agent_tool.dart';

/// State of the one-time "install this agent tool" flow (codex or hermes).
///
/// Both install via Homebrew (`brew install …`). Brew doesn't need `sudo`, but a
/// GUI app can't stream a Homebrew install reliably (and shouldn't run system
/// installers silently — see the no-auto-install rule), so we hand off to
/// Terminal and re-check on Continue, mirroring the built-in engine setup.
sealed class AgentSetupState {
  const AgentSetupState();
}

/// Nothing running yet — the initial state.
class AgentSetupIdle extends AgentSetupState {
  const AgentSetupIdle();
}

/// The install was opened in Terminal; waiting for the user to finish and press
/// Continue. [note] is an optional hint after a Continue that didn't yet detect
/// the tool.
class AgentSetupInstalling extends AgentSetupState {
  const AgentSetupInstalling({this.note});
  final String? note;
}

/// The tool is installed and its backend can be turned on.
class AgentSetupDone extends AgentSetupState {
  const AgentSetupDone();
}

/// Setup can't proceed; [message] is user-facing and actionable.
class AgentSetupFailed extends AgentSetupState {
  const AgentSetupFailed(this.message);
  final String message;
}

/// One shared install controller — the setup dialog is modal (one tool at a
/// time), so it targets whichever [AgentTool] the current flow was started for.
final agentInstallControllerProvider =
    NotifierProvider<AgentInstallController, AgentSetupState>(
      AgentInstallController.new,
    );

/// Drives a tool install: open `brew install …` in Terminal, then re-check on
/// Continue. Homebrew itself is a prerequisite the built-in engine setup already
/// owns; if it's missing we point the user there rather than re-driving the
/// Homebrew bootstrap here (kept in one place).
class AgentInstallController extends Notifier<AgentSetupState> {
  AgentTool _tool = AgentTool.codex;

  AgentToolInfo get _info => kAgentTools[_tool]!;

  @override
  AgentSetupState build() => const AgentSetupIdle();

  /// Begin (or retry) setup for [tool]: install via brew in Terminal, or fail
  /// with guidance when Homebrew is missing.
  Future<void> start(AgentTool tool) async {
    _tool = tool;
    if (!ref.read(homebrewInstalledProvider)) {
      state = const AgentSetupFailed(
        'Homebrew is required first. Set up the built-in engine on the Engines '
        'tab (that installs Homebrew), or install it from brew.sh, then come '
        'back.',
      );
      return;
    }
    final opened = await ref
        .read(hostShellServiceProvider)
        .openTerminal(_info.brewInstallCommand);
    if (!opened) {
      state = AgentSetupFailed(
        "Couldn't open Terminal. Run '${_info.brewInstallCommand}' manually, "
        'then press Continue.',
      );
      return;
    }
    state = const AgentSetupInstalling();
  }

  /// Re-checks for the tool after the Terminal install. Wired to "Continue".
  void continueSetup() {
    ref.invalidate(agentToolPathProvider(_tool));
    if (ref.read(agentToolInstalledProvider(_tool))) {
      state = const AgentSetupDone();
      return;
    }
    state = AgentSetupInstalling(
      note:
          "${_info.displayName} isn't detected yet. Finish the install in "
          'Terminal, then press Continue.',
    );
  }

  /// Re-opens the install in Terminal (e.g. the user closed the window).
  Future<void> reopenTerminal() =>
      ref.read(hostShellServiceProvider).openTerminal(_info.brewInstallCommand);
}
