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
/// [prompt] is the first thing to say, handed over as the CLI's own positional
/// argument rather than typed at it. Both take one (`claude [options] [prompt]`,
/// `codex [OPTIONS] [PROMPT]`) and both open the interactive UI with it already
/// sent — verified against `claude 2.1.245` in a pty, which drew its TUI and
/// answered the question.
///
/// **This is why the first message of a terminal chat is not typed in.** Typing
/// it would mean guessing when the CLI is ready to be typed at: too early and
/// the keystrokes land in a program that hasn't set up its input yet, too late
/// and the user is watching a prompt they already pressed Enter on. Worse, a
/// first-run dialog ("Detected a custom API key… use it?") would eat the Return
/// as its own answer. An argument has none of those problems.
///
/// [config] is Codex's `-c` overrides (the grid, the model, the provider), the
/// same list the one-shot lane builds. Claude Code takes its grid in the
/// environment instead, so it ignores this.
/// The conversation an interactive CLI should be holding: its id, and whether
/// that id already names one.
///
/// The two are not the same argument to either program, which is why this is a
/// pair rather than a nullable id. Claude Code is *told* the id up front
/// (`--session-id`) and asked for it back later (`--resume`) — and refuses
/// `--session-id` for a session that exists, so the flag has to change once the
/// first launch is done. Codex cannot be told one at all, so [resume] is only
/// ever true for it, on an id read back off the rollout it wrote
/// (`newCodexSessionId`).
typedef AgentSession = ({String id, bool resume});

ShellCommand agentTerminalCommand({
  required AgentTool tool,
  required String executable,
  required String model,
  required String workdir,
  required AgentApprovalMode approval,
  String? mcpConfigPath,
  List<String> config = const [],
  AgentSession? session,
  String? prompt,
}) => (
  executable: executable,
  arguments: switch (tool) {
    AgentTool.claude => _claudeTerminalArgs(
      model: model,
      approval: approval,
      mcpConfigPath: mcpConfigPath,
      session: session,
      prompt: prompt,
    ),
    AgentTool.codex => _codexTerminalArgs(
      model: model,
      workdir: workdir,
      approval: approval,
      config: config,
      session: session,
      prompt: prompt,
    ),
    // Hermes has no interactive CLI this app drives — it speaks ACP, and that
    // is the whole of it. [AgentTool.hasInteractiveCli] is what keeps a chat
    // from ever reaching here with it.
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
  required AgentSession? session,
  required String? prompt,
}) => [
  if (session != null)
    ...(session.resume
        ? ['--resume', session.id]
        : ['--session-id', session.id]),
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
  // Last, because it is the positional: `claude [options] [prompt]`.
  ?prompt,
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
  required AgentSession? session,
  required String? prompt,
}) {
  final gate = codexApprovalPolicy(approval);
  return [
    // `resume` is a subcommand, not a flag, so it leads — and the id goes with
    // it rather than after the options. `codex resume --help` documents
    // `[OPTIONS] [SESSION_ID]`, but keeping the positional next to the word that
    // takes it is what stops a variadic option (`-i/--image <FILE>...`) from
    // ever swallowing it, the same rule the one-shot argv follows.
    if (session != null && session.resume) ...['resume', session.id],
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
    // `codex [OPTIONS] [PROMPT]`, and only for a session that is starting
    // fresh: `codex resume` takes a session id in that slot, and a prompt put
    // there would be read as one.
    if (prompt != null && !(session?.resume ?? false)) prompt,
  ];
}
