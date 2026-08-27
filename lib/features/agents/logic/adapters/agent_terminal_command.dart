import '../../../../infrastructure/cli/agent_event.dart';
import '../../../../infrastructure/cli/claude_exec_service.dart'
    show kClaudeSessionSchedulerTools;
import '../../../../infrastructure/cli/codex_app_server_service.dart'
    show codexApprovalPolicy;
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
/// agents any other way — a pty is the only channel that carries the CLI's own
/// interface, which is why this lane exists beside [claudeExecArgs].
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
    AgentTool.hermes => _hermesTerminalArgs(
      model: model,
      approval: approval,
      session: session,
    ),
  },
);

/// How much of this computer an interactive Claude Code session may touch, as
/// the flags it starts with.
///
/// **"Read only" and "ask first" deliberately pass no flag at all.** The
/// interactive CLI's own default gate *is* the asking one: it stops at what
/// needs a yes and asks in its own TUI, where the user answers from the
/// keyboard. Naming a mode this build may not accept would fail the session
/// before it drew anything, and there is nothing to gain — the default is
/// already the behaviour both modes describe.
///
/// The one real difference between them is what the *user* then answers, which
/// is the point of a lane that can ask. The JSON lane holds the same two modes
/// apart app-side instead, where the app is the gate — see
/// `agentPermissionDecision`.
List<String> claudePermissionArgs(AgentApprovalMode mode) => switch (mode) {
  AgentApprovalMode.readOnly || AgentApprovalMode.ask => const [],
  AgentApprovalMode.plan => const ['--permission-mode', 'plan'],
  AgentApprovalMode.full => const ['--permission-mode', 'bypassPermissions'],
};

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

/// How much of this computer an interactive Hermes session may touch.
///
/// **Three of the four modes pass nothing, and that is deliberate.** Hermes's
/// own default gate is the asking one — it stops at what needs a yes and renders
/// the question as a modal panel in its TUI, where the user answers from the
/// keyboard. That is exactly what "read only", "ask first" and "plan" describe
/// from this side.
///
/// `-t/--toolsets` and `--safe-mode` are **deliberately not mapped**. They are
/// real enforcement rather than a hint, and the toolset names this build accepts
/// have not been measured; a flag guessed here would be the app promising a
/// narrower session than it actually asked for. Until they are measured, the
/// honest mapping is the one that changes nothing.
///
/// See `codexApprovalPolicy` and `claudePermissionArgs` for the other two, and
/// `decideAgentPermission` for the lane where the app is the gate instead.
List<String> hermesPermissionArgs(AgentApprovalMode mode) => switch (mode) {
  AgentApprovalMode.readOnly ||
  AgentApprovalMode.ask ||
  AgentApprovalMode.plan => const [],
  AgentApprovalMode.full => const ['--yolo'],
};

/// `hermes --tui`: the modern TUI rather than the classic REPL, on this chat's
/// model.
///
/// **No folder in the argv.** `hermes` has no flag for one — its only
/// positional is a subcommand — and the pty already opens in the chat's
/// folder, which is all a program needs to be in it. An `--in <dir>` was
/// passed here once, measured against 0.20.5; on the 0.19.0 this app installs
/// it is not a flag at all, so the path fell into the `command` slot and the
/// session died on `invalid choice: '/Users/…/agent-workspace'` before it
/// drew anything. The one folder-shaped thing the CLI does take is
/// `--no-restore-cwd`, which is the *opposite* instruction — stay where the
/// pty put you rather than `cd` into where a resumed session was recorded.
///
/// **There is no opening prompt in this argv, because `hermes` has no slot for
/// one.** Its only positional is a subcommand, and free text belongs to
/// `-z/--oneshot`, which is a different mode that never draws the TUI (measured
/// on 0.20.5). So a terminal chat with Hermes delivers its first message the way
/// a handover is delivered — pasted once the program has taken the keyboard, see
/// `AgentTerminals._pasteWhenReady`. That is the one place this lane is weaker
/// than the other two, and it is a property of the CLI rather than a choice.
///
/// [session] is resumed by **title**, not by id: the app renames the session it
/// discovers to a name of its own and resumes that from then on — see
/// `HermesSessionSource`. `--resume` takes either, and a missing one is not
/// fatal here (Hermes prints `· error: session not found` and opens a fresh
/// session), which is what lets that scheme repair itself.
List<String> _hermesTerminalArgs({
  required String model,
  required AgentApprovalMode approval,
  required AgentSession? session,
}) => [
  '--tui',
  // Hermes restores a resumed session's recorded directory unless told
  // otherwise, and the folder this chat is about is the app's to decide — it
  // is the one the pty opened in.
  '--no-restore-cwd',
  '-m',
  model,
  if (session != null) ...['--resume', session.id],
  ...hermesPermissionArgs(approval),
];
