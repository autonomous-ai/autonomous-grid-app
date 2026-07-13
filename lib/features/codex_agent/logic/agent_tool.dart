import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/host_environment.dart';

/// An external CLI that can back the Chat tab's Agent mode. Both are agent loops
/// the app spawns and streams into the chat; each installs via Homebrew and is
/// found on the augmented PATH (no bundled sidecar).
enum AgentTool { codex, hermes }

/// Static facts about an [AgentTool] — one source of truth so the picker, the
/// setup dialog and the senders agree on names, the executable to probe, and the
/// Homebrew install command.
class AgentToolInfo {
  const AgentToolInfo({
    required this.tool,
    required this.displayName,
    required this.executable,
    required this.brewInstallCommand,
    required this.blurb,
  });

  final AgentTool tool;
  final String displayName;

  /// Binary name to look for on PATH (also what we spawn).
  final String executable;

  /// The Homebrew command that installs it, run in Terminal.
  final String brewInstallCommand;

  /// One line for the setup dialog: what it is.
  final String blurb;
}

const Map<AgentTool, AgentToolInfo> kAgentTools = {
  // waiting BE support - CodeX
  // AgentTool.codex: AgentToolInfo(
  //   tool: AgentTool.codex,
  //   displayName: 'Codex',
  //   executable: 'codex',
  //   brewInstallCommand: 'brew install --cask codex',
  //   blurb: "OpenAI's coding agent. Reads files and runs read-only tasks.",
  // ),
  AgentTool.hermes: AgentToolInfo(
    tool: AgentTool.hermes,
    displayName: 'Hermes',
    executable: 'hermes',
    brewInstallCommand: 'brew install hermes-agent',
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
