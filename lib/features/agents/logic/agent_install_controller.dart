import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agent/logic/agent_server_error.dart';
import '../../agent/logic/hermes_tool.dart';
import 'agent_catalog.dart';
import 'agent_installer.dart';
import 'agent_status.dart';

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

/// [tool] finished installing or updating. [message] is the outcome in the
/// user's terms — whether it was already the latest build or just moved to a
/// newer one — so the button gives a plain answer instead of appearing to do
/// nothing (the app can't know a newer build exists until it has pulled one).
class AgentInstallDone extends AgentInstallState {
  const AgentInstallDone(this.tool, this.message);
  final AgentTool tool;
  final String message;
}

final agentInstallProvider =
    NotifierProvider<AgentInstallController, AgentInstallState>(
      AgentInstallController.new,
    );

/// Drives the Agents-tab Install/Update button: the install itself is
/// [AgentInstaller]'s (one router for every agent), and this wraps it in the
/// screen's state — the running spinner, the before/after version diff, and the
/// ACP repair Hermes needs — so a row shows an honest outcome instead of a bare
/// exit code.
class AgentInstallController extends Notifier<AgentInstallState> {
  @override
  AgentInstallState build() => const AgentInstallIdle();

  /// Fetch [tool]. [upgrade] reinstalls one that's already present.
  Future<void> install(AgentTool tool, {bool upgrade = false}) async {
    if (state is AgentInstallRunning) return;

    state = AgentInstallRunning(tool);
    // The build that's there now, read before the reinstall replaces it — so the
    // outcome can say whether anything actually changed. Only meaningful on an
    // upgrade; a fresh install has nothing before it.
    final before = upgrade ? await _installedVersion(tool) : null;

    final failed = await ref
        .read(agentInstallerProvider)
        .install(tool, upgrade: upgrade);
    if (failed != null) {
      state = AgentInstallFailed(tool, failed);
      return;
    }

    // The binary is on PATH now (or gone, if the user removed it) — re-probe the
    // one we installed, so its row stops claiming what it said beforehand.
    reprobeAgent(ref, tool);

    final unfinished = await _finishAcpSetup(tool);
    if (unfinished != null) {
      state = AgentInstallFailed(tool, unfinished);
      return;
    }
    // Re-read after the re-probe: the build now on the machine, to compare
    // against [before] and report the honest outcome.
    final after = await _installedVersion(tool);
    state = AgentInstallDone(
      tool,
      agentInstallOutcome(tool, upgrade: upgrade, before: before, after: after),
    );
  }

  /// The installed build of [tool], or null when it doesn't report one.
  Future<String?> _installedVersion(AgentTool tool) =>
      ref.read(agentVersionProvider(tool).future);

  /// Make sure Hermes can actually serve ACP — the mode chat drives it in.
  ///
  /// The CLI on this machine may be an older build, which installs Hermes
  /// without that piece: the row would then read "installed" while every chat
  /// turn failed. Installing is the moment to finish the job, so Update repairs
  /// such a machine instead of running the same broken install again. Returns
  /// null when there's nothing to do (or it worked), else the line to show.
  Future<String?> _finishAcpSetup(AgentTool tool) async {
    if (tool != AgentTool.hermes) return null;
    final setup = ref.read(hermesAcpSetupProvider);
    if (setup == null || await setup.isReady()) return null;
    // The raw reason is logged by the repair itself (§6) — this is the line the
    // user reads.
    return await setup.repair() == null
        ? null
        : '$kAgentSetupUnfinished It needs a connection to download the rest — '
              'check yours and try again.';
  }

  void clearError() {
    if (state is AgentInstallFailed) state = const AgentInstallIdle();
  }
}

/// The outcome line shown after an install or update finishes.
///
/// The app can't know a newer build exists until it has pulled one, so an
/// "update" always reinstalls the latest and then compares the build [before] it
/// ran against the one [after]: unchanged reads as already-current, a new number
/// as an update. A build that reports no version can only be said to have been
/// reinstalled — never claimed up to date on evidence it doesn't have.
String agentInstallOutcome(
  AgentTool tool, {
  required bool upgrade,
  required String? before,
  required String? after,
}) {
  final name = tool.name;
  if (!upgrade) {
    return after == null ? 'Installed $name.' : 'Installed $name · v$after';
  }
  if (after == null) return 'Reinstalled $name.';
  if (before == after) return '$name is already up to date · v$after';
  return 'Updated $name to v$after';
}
