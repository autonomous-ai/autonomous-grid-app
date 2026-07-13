import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/host_environment.dart';

/// An external CLI that can back the Chat tab's Agent mode. Both are agent loops
/// the app spawns and streams into the chat; both are found on the augmented
/// PATH (no bundled sidecar).
enum AgentTool { codex, hermes }

/// How a tool gets onto the machine.
sealed class AgentInstall {
  const AgentInstall();
}

/// The `grid` CLI installs it — `grid agent install <name>` fetches a pinned
/// `uv` and a private Python into `~/.grid`. No package manager, no admin
/// rights, nothing for the user to type: the app can just run it.
class GridCliInstall extends AgentInstall {
  const GridCliInstall(this.name);
  final String name;
}

/// Homebrew installs it, handed off to Terminal. Homebrew's installer needs an
/// interactive `sudo`, which a GUI app cannot drive — so the user finishes it in
/// a terminal window and presses Continue.
class BrewInstall extends AgentInstall {
  const BrewInstall(this.command);
  final String command;
}

/// Static facts about an [AgentTool] — one source of truth so the picker, the
/// setup dialog and the senders agree on names, the executable to probe, and how
/// it is installed.
class AgentToolInfo {
  const AgentToolInfo({
    required this.tool,
    required this.displayName,
    required this.executable,
    required this.install,
    required this.blurb,
  });

  final AgentTool tool;
  final String displayName;

  /// Binary name to look for on PATH (also what we spawn).
  final String executable;

  /// How to install it when it's missing.
  final AgentInstall install;

  /// One line for the setup dialog: what it is.
  final String blurb;
}

const Map<AgentTool, AgentToolInfo> kAgentTools = {
  AgentTool.codex: AgentToolInfo(
    tool: AgentTool.codex,
    displayName: 'Codex',
    executable: 'codex',
    install: BrewInstall('brew install --cask codex'),
    blurb: "OpenAI's coding agent. Reads files and runs read-only tasks.",
  ),
  AgentTool.hermes: AgentToolInfo(
    tool: AgentTool.hermes,
    displayName: 'Hermes',
    executable: 'hermes',
    install: GridCliInstall('hermes'),
    blurb: "Nous Research's agent. Works with the grid today (no wait).",
  ),
};

/// Absolute path to a tool's binary, or null when it isn't installed. Invalidate
/// to re-probe after an install.
final agentToolPathProvider = Provider.family<String?, AgentTool>(
  (ref, tool) => HostEnvironment.findExecutable(kAgentTools[tool]!.executable),
);

/// Whether a tool is installed on this computer.
final agentToolInstalledProvider = Provider.family<bool, AgentTool>(
  (ref, tool) => ref.watch(agentToolPathProvider(tool)) != null,
);
