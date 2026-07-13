import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/host_shell_service.dart';
import '../../../infrastructure/providers.dart';
import 'agent_tool.dart';

/// Longest a one-off agent install may run before we call it stuck. Hermes
/// downloads a private Python and a few dozen packages, so the ceiling is
/// generous — but it exists, or a wedged install would spin forever.
const _installTimeout = Duration(minutes: 10);

/// Stand-in exit code for "we gave up waiting" — no real exit code, so the
/// timeout is distinguishable from a process that actually failed.
const _timeoutExitCode = -1;

/// Lines of installer output kept for the dialog. Enough to show what's
/// happening; not so many that a chatty installer grows the state without bound.
const _maxLogLines = 200;

/// State of the one-time "install this agent tool" flow.
///
/// Hermes installs in-app: `grid agent install hermes` fetches a pinned `uv` and
/// a private Python into `~/.grid` — no Homebrew, no admin rights, nothing for
/// the user to type. Codex still hands off to Terminal (`brew install --cask`);
/// it is debug-only, so the hand-off stays behind [AgentSetupAwaitingTerminal]
/// rather than blocking the shipped path on Homebrew.
sealed class AgentSetupState {
  const AgentSetupState();
}

/// Nothing running yet — the initial state.
class AgentSetupIdle extends AgentSetupState {
  const AgentSetupIdle();
}

/// The app is installing the tool itself. [log] is the installer's latest output.
class AgentSetupRunning extends AgentSetupState {
  const AgentSetupRunning(this.log);
  final List<String> log;
}

/// The install was handed off to Terminal; waiting for the user to finish and
/// press Continue. [note] is a hint after a Continue that didn't yet find it.
class AgentSetupAwaitingTerminal extends AgentSetupState {
  const AgentSetupAwaitingTerminal({this.note});
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

class AgentInstallController extends Notifier<AgentSetupState> {
  AgentTool _tool = AgentTool.hermes;

  AgentToolInfo get _info => kAgentTools[_tool]!;

  @override
  AgentSetupState build() => const AgentSetupIdle();

  /// Begin (or retry) setup for [tool].
  Future<void> start(AgentTool tool) async {
    _tool = tool;
    return switch (_info.install) {
      GridCliInstall(:final name) => _installWithCli(name),
      BrewInstall(:final command) => _installInTerminal(command),
    };
  }

  /// Runs `grid agent install <name>` and streams its output into the dialog.
  Future<void> _installWithCli(String name) async {
    final service = ref.read(gridCliServiceProvider);
    if (service == null) {
      state = const AgentSetupFailed(
        "Grid isn't ready yet. Restart the app and try again.",
      );
      return;
    }

    state = const AgentSetupRunning([]);
    final log = <String>[];

    final process = await service.start(['agent', 'install', name]);

    final subscription = process.lines.listen((line) {
      log.add(line.text);
      if (log.length > _maxLogLines) log.removeAt(0);
      state = AgentSetupRunning(List.unmodifiable(log));
    });

    final timedOut = await process.exitCode
        .timeout(
          _installTimeout,
          onTimeout: () {
            process.kill();
            return _timeoutExitCode;
          },
        )
        .whenComplete(subscription.cancel)
        .then((code) => code == _timeoutExitCode);

    ref.invalidate(agentToolPathProvider(_tool));
    if (ref.read(agentToolInstalledProvider(_tool))) {
      state = const AgentSetupDone();
      return;
    }
    state = AgentSetupFailed(
      timedOut
          ? '${_info.displayName} is taking too long to install. Check your '
                'internet connection and try again.'
          : "${_info.displayName} couldn't be installed. Check your internet "
                'connection and try again.',
    );
  }

  /// Codex only: hand `brew install …` to Terminal, then re-check on Continue.
  /// Homebrew can't be driven from a GUI app (it needs an interactive `sudo`).
  Future<void> _installInTerminal(String command) async {
    final opened = await ref
        .read(hostShellServiceProvider)
        .openTerminal(command);
    if (!opened) {
      state = AgentSetupFailed(
        "Couldn't open Terminal. Run '$command' manually, then press Continue.",
      );
      return;
    }
    state = const AgentSetupAwaitingTerminal();
  }

  /// Re-checks for the tool after a Terminal install. Wired to "Continue".
  void continueSetup() {
    ref.invalidate(agentToolPathProvider(_tool));
    if (ref.read(agentToolInstalledProvider(_tool))) {
      state = const AgentSetupDone();
      return;
    }
    state = AgentSetupAwaitingTerminal(
      note:
          "${_info.displayName} isn't detected yet. Finish the install in "
          'Terminal, then press Continue.',
    );
  }

  /// Re-opens a Terminal install (e.g. the user closed the window).
  Future<void> reopenTerminal() async {
    if (_info.install case BrewInstall(:final command)) {
      await ref.read(hostShellServiceProvider).openTerminal(command);
    }
  }
}
