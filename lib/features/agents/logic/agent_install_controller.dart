import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/claude_installer.dart';
import '../../../infrastructure/cli/grid_cli_service.dart';
import '../../../infrastructure/providers.dart';
import '../../agent/logic/agent_server_error.dart';
import '../../agent/logic/hermes_tool.dart';
import 'agent_catalog.dart';
import 'agent_status.dart';

/// Ceiling for `grid agent install`, well past the default one-shot timeout:
/// it downloads a private CPython plus the agent's dependencies, which takes
/// minutes — and longer on an Intel Mac that has no prebuilt wheels and builds
/// from source. The old 60s default killed the install mid-download every time,
/// so both the silent top-up and the Agents-screen "Update" always failed. This
/// stays a ceiling, not a promise it finishes — a genuinely wedged install still
/// gives up rather than hanging the screen forever.
const Duration kAgentInstallTimeout = Duration(minutes: 10);

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

/// Installs (or upgrades) an agent — no Homebrew, no admin rights.
///
/// Two routes, because the agents come from two places: `grid agent install`
/// for the ones the CLI packages (Hermes, Codex), and the vendor's own
/// installer for Claude Code, which the CLI has no recipe for. Which route an
/// agent takes is this class's business alone — every screen just presses
/// Install.
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

    final failed = tool == AgentTool.claude
        ? await _installClaude(upgrade: upgrade)
        : await _installViaCli(tool, upgrade: upgrade);
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

  /// `grid agent install <id>` — the path for the agents the CLI knows how to
  /// fetch (Hermes, Codex). Returns null on success, else the line to show.
  Future<String?> _installViaCli(AgentTool tool, {required bool upgrade}) async {
    final cli = ref.read(gridCliServiceProvider);
    if (cli == null) {
      return "The grid tool isn't installed on this computer, so there's "
          'nothing to install ${tool.name} with.';
    }
    final result = await cli.run([
      'agent',
      'install',
      tool.id,
      if (upgrade) '--force',
    ], timeout: kAgentInstallTimeout);
    return result.ok ? null : _friendlyError(result, tool);
  }

  /// Claude Code comes from its vendor's own installer, because `grid agent
  /// install` has no recipe for it — it knows Hermes and Codex and rejects
  /// anything else at argv parsing, so routing Claude through it would fail
  /// every time with a usage error the user can do nothing about.
  Future<String?> _installClaude({required bool upgrade}) async {
    final failure = await ref
        .read(claudeInstallerProvider)
        .install(upgrade: upgrade);
    if (failure == null) return null;
    // The raw line is kept, not swallowed: an installer that failed on a proxy
    // says so, and a sentence of ours would only hide it (§6).
    return "Couldn't install ${AgentTool.claude.name}: $failure";
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
