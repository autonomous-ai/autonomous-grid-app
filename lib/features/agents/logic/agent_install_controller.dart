import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/grid_cli_service.dart';
import '../../../infrastructure/providers.dart';
import '../../agent/agent_definition.dart';
import 'agent_status.dart';

sealed class AgentInstallState {
  const AgentInstallState();
}

class AgentInstallIdle extends AgentInstallState {
  const AgentInstallIdle();
}

/// [agent] is being fetched right now — it downloads, so the row says so and the
/// button can't be pressed twice.
class AgentInstallRunning extends AgentInstallState {
  const AgentInstallRunning(this.agent);
  final AgentDefinition agent;
}

class AgentInstallFailed extends AgentInstallState {
  const AgentInstallFailed(this.agent, this.message);
  final AgentDefinition agent;
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

  /// Fetch [agent]. [upgrade] reinstalls one that's already present.
  Future<void> install(AgentDefinition agent, {bool upgrade = false}) async {
    if (state is AgentInstallRunning) return;
    // A standalone-install agent isn't ours to fetch — `grid agent install`
    // would reject the name. The Agents screen sends the user to its site
    // instead; guard here so a mis-wire can't run a doomed command.
    if (agent.installUrl != null) return;

    final cli = ref.read(gridCliServiceProvider);
    if (cli == null) {
      state = AgentInstallFailed(
        agent,
        "The grid tool isn't installed on this computer, so there's nothing to "
        'install ${agent.name} with.',
      );
      return;
    }

    state = AgentInstallRunning(agent);
    final result = await cli.run([
      'agent',
      'install',
      agent.id,
      if (upgrade) '--force',
    ]);
    if (!result.ok) {
      state = AgentInstallFailed(agent, _friendlyError(result, agent));
      return;
    }

    // The binary is on PATH now (or gone, if the user removed it) — re-probe the
    // one we installed, so its row stops claiming what it said beforehand.
    reprobeAgent(ref, agent);

    // Some agents finish installing themselves on the first run (Hermes repairs
    // its ACP support); most have nothing to do and return null.
    final unfinished = await agent.finishInstall(ref);
    if (unfinished != null) {
      state = AgentInstallFailed(agent, unfinished);
      return;
    }
    state = const AgentInstallIdle();
  }

  void clearError() {
    if (state is AgentInstallFailed) state = const AgentInstallIdle();
  }
}

/// The CLI's last words, or a plain sentence when it said nothing useful — never
/// a bare exit code, which tells the user nothing they can do something about.
String _friendlyError(CliResult result, AgentDefinition agent) {
  final detail = [
    ...result.stderr.trim().split('\n'),
    ...result.stdout.trim().split('\n'),
  ].map((line) => line.trim()).where((line) => line.isNotEmpty).lastOrNull;

  if (detail == null) {
    return "Couldn't install ${agent.name}. Check your connection and try "
        'again.';
  }
  return "Couldn't install ${agent.name}: $detail";
}
