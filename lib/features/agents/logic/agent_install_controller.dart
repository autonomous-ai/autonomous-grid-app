import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/grid_cli_service.dart';
import '../../../infrastructure/cli/hermes_version_service.dart';
import '../../../infrastructure/providers.dart';
import '../../agent/logic/codex_tool.dart';
import '../../agent/logic/hermes_tool.dart';
import 'agent_catalog.dart';

sealed class AgentInstallState {
  const AgentInstallState();
}

class AgentInstallIdle extends AgentInstallState {
  const AgentInstallIdle();
}

/// [tool] is being fetched right now — it downloads, so the row says so and the
/// button can't be pressed twice.
class AgentInstallRunning extends AgentInstallState {
  const AgentInstallRunning(this.tool);
  final AgentTool tool;
}

class AgentInstallFailed extends AgentInstallState {
  const AgentInstallFailed(this.tool, this.message);
  final AgentTool tool;
  final String message;
}

final agentInstallProvider =
    NotifierProvider<AgentInstallController, AgentInstallState>(
      AgentInstallController.new,
    );

/// Installs (or upgrades) an agent through the `grid` CLI — no Homebrew, no
/// admin rights: `grid agent install <id>`, with `--force` to replace a build
/// that's already there.
class AgentInstallController extends Notifier<AgentInstallState> {
  @override
  AgentInstallState build() => const AgentInstallIdle();

  /// Fetch [tool]. [upgrade] reinstalls one that's already present.
  ///
  /// An agent the app can't run has no install path at all — the CLI only knows
  /// Hermes — so this refuses rather than shelling out to a command that would
  /// fail with a CLI error the user can't act on.
  Future<void> install(AgentTool tool, {bool upgrade = false}) async {
    if (!tool.runnable || state is AgentInstallRunning) return;

    final cli = ref.read(gridCliServiceProvider);
    if (cli == null) {
      state = AgentInstallFailed(
        tool,
        "The grid tool isn't installed on this computer, so there's nothing to "
        'install ${tool.name} with.',
      );
      return;
    }

    state = AgentInstallRunning(tool);
    final result = await cli.run([
      'agent',
      'install',
      tool.id,
      if (upgrade) '--force',
    ]);
    if (!result.ok) {
      state = AgentInstallFailed(tool, _friendlyError(result, tool));
      return;
    }

    // The binary is on PATH now (or gone, if the user removed it) — re-probe the
    // one we installed, so its row stops claiming what it said beforehand.
    _reprobe(tool);
    state = const AgentInstallIdle();
  }

  /// Re-read whether [tool] is present and which build it is, after installing
  /// or updating it. Only runnable agents reach here (install guards the rest).
  void _reprobe(AgentTool tool) {
    switch (tool) {
      case AgentTool.hermes:
        ref.invalidate(hermesPathProvider);
        ref.invalidate(hermesVersionProvider);
      case AgentTool.codex:
        ref.invalidate(codexPathProvider);
        ref.invalidate(codexVersionProvider);
      case AgentTool.openclaw:
        // Planned, not installable — never installed, so nothing to re-probe.
        break;
    }
  }

  void clearError() {
    if (state is AgentInstallFailed) state = const AgentInstallIdle();
  }
}

/// The CLI's last words, or a plain sentence when it said nothing useful — never
/// a bare exit code, which tells the user nothing they can do something about.
String _friendlyError(CliResult result, AgentTool tool) {
  final detail = [
    ...result.stderr.trim().split('\n'),
    ...result.stdout.trim().split('\n'),
  ].map((line) => line.trim()).where((line) => line.isNotEmpty).lastOrNull;

  if (detail == null) {
    return "Couldn't install ${tool.name}. Check your connection and try again.";
  }
  return "Couldn't install ${tool.name}: $detail";
}
