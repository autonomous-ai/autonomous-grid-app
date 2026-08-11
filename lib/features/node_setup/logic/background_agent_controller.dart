import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/logging/app_log.dart';
import '../../agents/logic/agent_catalog.dart';
import '../../agents/logic/agent_installer.dart';
import '../../agents/logic/agent_status.dart';
import 'node_capabilities.dart';

final backgroundAgentInstallerProvider = Provider<BackgroundAgentInstaller>(
  BackgroundAgentInstaller.new,
);

/// Quietly fetches the agents this computer is missing, the moment the user is
/// in.
///
/// This is the one place every agent installs the same way at startup — through
/// [AgentInstaller], which knows the route for each (the app's own pinned,
/// hash-verified recipes for Hermes, Codex and Pi; the vendor script for Claude
/// Code). The full-screen first-run installer only guarantees the chat
/// assistant before letting the user in; the rest arrive here, so a machine set
/// up before an agent joined the catalog tops itself up instead of sitting
/// forever with a row the user can only look at.
///
/// Silent on purpose: none of the installers need Homebrew or admin rights —
/// every recipe writes into `~/.grid`, Claude Code's script into `~/.local/bin`
/// — so an extra assistant that wouldn't download is not worth interrupting
/// anyone about. The Agents tab still offers Install, and each installer's own
/// words go to the app log rather than nowhere.
///
/// TODO(BE): "silent" now covers a **~350 MB** download on a machine that has
/// none of them — Pi brings its own Node toolchain (~180 MB unpacked) on top of
/// its packages, and this round fetches it on a metered connection without
/// saying so. Either move Pi behind first use (its row already has Install) or
/// let this round say what it is fetching.
class BackgroundAgentInstaller {
  BackgroundAgentInstaller(this._ref);

  final Ref _ref;

  /// Guards against a second run in the same session — the shell can fire this
  /// from more than one place, and each install spawns a process.
  bool _attempted = false;

  /// Install whatever is missing. Safe to call whenever the shell mounts: it
  /// no-ops on a machine that already has every agent.
  Future<void> startIfNeeded() async {
    if (_attempted) return;
    // Claim the slot before the first await, so a second call can't start a
    // second round of installs.
    _attempted = true;

    final caps = await _ref.read(nodeCapabilitiesProvider.future);
    final missing = [
      for (final tool in AgentTool.values)
        if (!caps.installedAgents.contains(tool)) tool,
    ];
    if (missing.isEmpty) return;

    final installer = _ref.read(agentInstallerProvider);
    final log = _ref.read(appLogProvider);
    var installedAny = false;
    for (final tool in missing) {
      log.info('agents', 'Installing ${tool.id} in the background');
      final failed = await installer.install(tool);
      if (failed == null) {
        installedAny = true;
      } else {
        log.warn('agents', "Couldn't install ${tool.id}: $failed");
      }
    }

    // Whatever landed, the rest of the app must stop answering with the probe it
    // took at launch — see [reprobeAgents]. Skipped when nothing installed, so a
    // round that only logged failures doesn't churn every agent provider.
    if (installedAny) reprobeAgents(_ref);
  }
}
