import '../../../../infrastructure/cli/agent_event.dart';
import '../../../../infrastructure/cli/raw_agent_argv.dart';
import '../../../../shared/terminal/terminal_shell.dart';
import '../agent_catalog.dart';

/// The agent's **own interactive CLI**, as a command for a pty — the same thing
/// the user would type in their terminal, pointed at this chat's grid and folder.
///
/// Pure, and unit-tested, because the failure mode is silent in the worst way:
/// a flag the interactive build doesn't take aborts before the TUI draws, and
/// what the user sees is a terminal that flashes and dies. Two of those were
/// found by reading `--help` rather than by shipping them —
/// `--skip-git-repo-check` is `codex exec`'s alone and is rejected by the
/// interactive `codex`, and `--input-format stream-json` is refused outright
/// unless the output is JSON too, which is what closed the door on driving these
/// agents any other way (see [claudeRawArgs]).
///
/// [executable] is the resolved binary — the path providers own that, so this
/// stays a function of its arguments.
///
/// [config] is Codex's `-c` overrides (the grid, the model, the provider), the
/// same list the one-shot lane builds. Claude Code takes its grid in the
/// environment instead, so it ignores this.
ShellCommand agentTerminalCommand({
  required AgentTool tool,
  required String executable,
  required String model,
  required String workdir,
  required AgentApprovalMode approval,
  String? mcpConfigPath,
  List<String> config = const [],
}) => (
  executable: executable,
  arguments: switch (tool) {
    AgentTool.claude => _claudeTerminalArgs(
      model: model,
      approval: approval,
      mcpConfigPath: mcpConfigPath,
    ),
    AgentTool.codex => _codexTerminalArgs(
      model: model,
      workdir: workdir,
      approval: approval,
      config: config,
    ),
    // Hermes has no interactive CLI this app drives — it speaks ACP, and that
    // is the whole of it. [AgentTool.runsInTerminal] is what keeps a chat from
    // ever reaching here with it.
    AgentTool.hermes => const <String>[],
  },
);

/// `claude`, with no `-p`: the real REPL, in the folder the pty opens in.
///
/// **The permission gate is back, and it is the CLI's own.** Interactive Claude
/// Code stops and asks in its own TUI, and the user answers with the keyboard —
/// which is why [claudePermissionArgs] passing nothing for "read only" and "ask
/// first" is right here rather than merely safe: the default gate *is* the
/// asking one. Plan and full access still name their mode.
///
/// The schedulers go on every session for the same reason they went on every
/// one-shot turn: they report success into a process that ends with the chat.
List<String> _claudeTerminalArgs({
  required String model,
  required AgentApprovalMode approval,
  required String? mcpConfigPath,
}) => [
  '--model',
  model,
  ...claudePermissionArgs(approval),
  '--disallowedTools',
  ...kClaudeSessionSchedulerTools,
  if (mcpConfigPath != null) ...[
    '--mcp-config',
    mcpConfigPath,
    '--strict-mcp-config',
  ],
];

/// `codex`, with no `exec`: the real TUI, told which folder is its working root.
///
/// `--skip-git-repo-check` is **deliberately absent** — `codex --help` does not
/// list it, so passing it here kills the session before it starts. The
/// interactive build has no equivalent; a chat in a folder that is not a repo
/// gets Codex's own prompt about it, which is the CLI behaving as the user's own
/// would.
List<String> _codexTerminalArgs({
  required String model,
  required String workdir,
  required AgentApprovalMode approval,
  required List<String> config,
}) {
  final gate = codexApprovalPolicy(approval);
  return [
    '-C',
    workdir,
    '-m',
    model,
    '-s',
    gate.sandbox,
    for (final override in [...config, 'approval_policy="${gate.policy}"']) ...[
      '-c',
      override,
    ],
  ];
}
