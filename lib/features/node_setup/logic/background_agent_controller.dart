import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_installer.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../agent/agent_registry.dart';
import '../../agents/logic/agent_status.dart';
import 'node_capabilities.dart';
import 'node_setup_plan.dart';

final backgroundAgentInstallerProvider = Provider<BackgroundAgentInstaller>(
  BackgroundAgentInstaller.new,
);

/// Quietly fetches the agents this computer is missing, once the user is in.
///
/// First-run setup installs every agent in the catalog ([agentInstallSteps]),
/// but a computer set up *before* an agent joined that catalog never runs the
/// plan again — it would sit forever with a row the user can only look at.
/// Topping up here keeps the full-screen installer for genuinely new machines
/// instead of putting it back in front of someone who is already set up.
///
/// Silent on purpose: the app installs into `~/.grid` — no Homebrew, no admin
/// rights, nothing to approve — and an extra assistant that wouldn't download is
/// not worth interrupting anyone about. The Agents tab still offers Install, and
/// the installer's own words go to the app log rather than nowhere.
class BackgroundAgentInstaller {
  BackgroundAgentInstaller(this._ref);

  final Ref _ref;

  /// Guards against a second run in the same session — the shell can fire this
  /// from more than one place, and each install spawns work.
  bool _attempted = false;

  /// Install whatever is missing. Safe to call whenever the shell mounts: it
  /// no-ops on a machine that already has every agent.
  Future<void> startIfNeeded() async {
    if (_attempted) return;
    // Claim the slot before the first await, so a second call can't start a
    // second round of installs.
    _attempted = true;

    final caps = await _ref.read(nodeCapabilitiesProvider.future);
    final missing = agentInstallSteps(caps);
    if (missing.isEmpty) return;

    final log = _ref.read(appLogProvider);
    final installer = _ref.read(agentInstallerProvider);
    for (final step in missing) {
      final agent = agentById(step.args.last);
      if (agent == null) continue;
      log.info('agents', 'Installing ${agent.id} in the background');
      try {
        await installer.run(
          agent.installSpec,
          onLog: (line) => log.info('agents', line),
        );
      } on Object catch (error) {
        log.warn('agents', "Couldn't install ${agent.id}: $error");
      }
    }

    // Whatever landed, the rest of the app must stop answering with the probe
    // it took at launch — see [reprobeAgents].
    reprobeAgents(_ref);
  }
}
