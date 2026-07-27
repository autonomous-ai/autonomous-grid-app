import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_installer.dart';
import '../../../infrastructure/logging/app_log.dart';
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

/// Installs (or upgrades) an agent — the app runs the agent's own install recipe
/// ([AgentDefinition.installSpec]) itself, no `grid agent install`: a pinned uv
/// tool, a hash-verified GitHub release binary, or a package-manager command,
/// all into `~/.grid` with no admin rights. The raw tool output streams to the
/// app log; the row shows a plain outcome.
class AgentInstallController extends Notifier<AgentInstallState> {
  @override
  AgentInstallState build() => const AgentInstallIdle();

  /// Fetch [agent]. [upgrade] reinstalls one that's already present.
  Future<void> install(AgentDefinition agent, {bool upgrade = false}) async {
    if (state is AgentInstallRunning) return;

    state = AgentInstallRunning(agent);
    final log = ref.read(appLogProvider);
    try {
      await ref
          .read(agentInstallerProvider)
          .run(
            agent.installSpec,
            upgrade: upgrade,
            onLog: (line) => log.info('agents', line),
          );
    } on AgentInstallException catch (error) {
      // The raw reason is already in the log via onLog; this is the line the
      // user reads.
      log.failure('agents', 'install ${agent.id}: ${error.message}');
      state = AgentInstallFailed(agent, _friendlyError(agent, error));
      return;
    } on Object catch (error) {
      log.failure('agents', 'install ${agent.id}: $error');
      state = AgentInstallFailed(
        agent,
        "Couldn't install ${agent.name}. Check your connection and try again.",
      );
      return;
    }

    // The binary is on PATH now — re-probe the one we installed, so its row
    // stops claiming what it said beforehand.
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

/// The installer's reason in plain language — a transient start/download failure
/// invites a retry; anything else keeps the tool's own last line.
String _friendlyError(AgentDefinition agent, AgentInstallException error) =>
    error.retryable
    ? "Couldn't start installing ${agent.name}. Check your connection and try "
          'again.'
    : "Couldn't install ${agent.name}: ${error.message}";
