import 'agent_event.dart';

/// Claude Code's own schedulers, taken away on every turn: none of them can work
/// here, and they fail by *succeeding*.
///
/// `CronCreate` keeps the job in the memory of the process that created it and
/// says so — "session-only, dies when Claude exits". In a REPL that is a fair
/// deal. Here a turn is a `claude -p` that exits the moment the answer is
/// finished, so on 2026-08-19 a user was told two jobs would scan every 30
/// minutes for seven days and both were gone twelve seconds later, with the
/// transcript ending at the message that promised them.
///
/// `ScheduleWakeup` is the same trap wearing the word the user actually says.
/// Taking only the cron tools away on 2026-08-19 left it as the nearest thing to
/// hand, and the next morning it was reached for twice inside eight minutes,
/// each time into a process that had already exited — and both turns ended by
/// telling the user the loop was on.
///
/// A repeat *inside a chat* is not lost with them: that is `/loop`, which the app
/// owns.
const List<String> kClaudeSessionSchedulerTools = [
  'CronCreate',
  'CronDelete',
  'CronList',
  'ScheduleWakeup',
];

/// The web tools the **provider** runs, rather than Claude Code itself.
///
/// Whatever answers the request has to understand them, and a grid model does
/// not: the relay has no chat-completions equivalent to translate them into and
/// refuses the whole request, so asking for today's weather spent a step on
/// `400 Unsupported tool type: web_search_20250305` before the agent fell back to
/// the `grid-web` skill. Denied up front, the fallback is simply the route.
const List<String> kClaudeServerWebTools = ['WebSearch', 'WebFetch'];

/// The argv for one raw Claude Code turn — no JSON asked for, and none read.
///
/// Pure, and unit-tested, because the failure mode is silent: a mistyped flag
/// looks exactly like a model that wouldn't answer (§7).
///
/// - `-p` alone prints the answer as text. The stream-json pair that used to be
///   here is gone, and with it everything that only existed inside it: the
///   activity feed, the plan, the session id a later turn resumed from, and the
///   `--permission-prompt-tool` channel — which the CLI only honours *with*
///   `--output-format stream-json`, so there is no way to keep it here.
/// - The prompt goes on **stdin**, not in argv, so a long replayed history can't
///   overflow an argv limit. This argv carries no positionals, which is what
///   keeps the variadic `--disallowedTools` below safe: it swallows every
///   following token until the next `--flag`.
/// - `--mcp-config` with `--strict-mcp-config` narrows the turn to the app's own
///   connectors. [mcpConfigPath] is nullable because a path that doesn't exist
///   aborts the turn outright, so a failed write must drop **both** flags rather
///   than pass a broken one.
/// - `--chrome` adds the Claude in Chrome extension's browser tools; a turn
///   holding the relay's credentials cannot use the extension at all.
/// - `--resume` still works here, but no chat turn passes it any more: the id
///   came out of the JSON stream's opening line, and there is no stream. It is
///   kept for the one caller that is *handed* an id — a session command against
///   a chat imported from the tool that opened it.
List<String> claudeRawArgs({
  required String model,
  required AgentApprovalMode approval,
  String? resumeSessionId,
  String? mcpConfigPath,
  bool chrome = false,
  bool withoutServerWebTools = false,
}) => [
  '-p',
  '--model',
  model,
  if (resumeSessionId != null) ...['--resume', resumeSessionId],
  ...claudePermissionArgs(approval),
  if (chrome) '--chrome',
  '--disallowedTools',
  ...kClaudeSessionSchedulerTools,
  if (withoutServerWebTools) ...kClaudeServerWebTools,
  if (mcpConfigPath != null) ...[
    '--mcp-config',
    mcpConfigPath,
    '--strict-mcp-config',
  ],
];

/// How much of this computer a raw Claude Code turn may touch, as flags.
///
/// **The composer's "ask first" can no longer ask.** Asking was
/// `--permission-prompt-tool`, and the CLI serves it only alongside
/// `--output-format stream-json`; without that channel Claude Code's own gate
/// stops at what needs a yes and says so in the text — which the chat now shows
/// verbatim, so the user reads the refusal in the agent's own words instead of
/// seeing a card. `readOnly` and `ask` therefore pass **no** mode flag at all and
/// take the CLI's own default: naming a mode this build may not accept would
/// fail the whole turn, and the default is the same gate.
///
/// TODO(BE): the picker still offers four modes while the middle two now behave
/// identically. The copy in the composer says "ask first" and nothing asks —
/// that is a lie on screen (§5) and wants either a reworded picker or the mode
/// removed.
List<String> claudePermissionArgs(AgentApprovalMode mode) => switch (mode) {
  AgentApprovalMode.readOnly || AgentApprovalMode.ask => const [],
  AgentApprovalMode.plan => const ['--permission-mode', 'plan'],
  AgentApprovalMode.full => const ['--permission-mode', 'bypassPermissions'],
};

/// The argv for one raw Codex turn — `codex exec`, without `--json`.
///
/// Pure and unit-tested, for the same reason as [claudeRawArgs].
///
/// - `exec` runs one turn and exits, printing its working-out and its answer as
///   text. Everything the app used to read off `app-server`'s JSON-RPC is gone
///   with it: the thread id a later turn resumed from, the approval requests,
///   the plan, and the file changes behind the chat's Open button.
/// - [config] is the run's configuration in `-c` form — the grid, the model, the
///   provider to reach them through (`codexGridOverrides`) — so a turn answers on
///   the app's grid without the user's own `~/.codex/config.toml` being
///   rewritten.
/// - `--skip-git-repo-check` because a chat's folder is not always a repo, and
///   `exec` refuses to start in one that isn't.
/// - `--color never` so the answer reaches the bubble as text rather than as
///   terminal escape codes.
List<String> codexRawArgs({
  required String model,
  required String workdir,
  required AgentApprovalMode approval,
  List<String> config = const [],
}) {
  final gate = codexApprovalPolicy(approval);
  return [
    'exec',
    '--color',
    'never',
    '--skip-git-repo-check',
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

/// The sandbox and approval policy one turn runs under, from what the user chose
/// in the composer.
///
/// Two of the three modes still mean what they say without a channel to ask on:
/// look-don't-touch can't write, and full access is a choice the user made. The
/// middle one no longer does — `untrusted` is Codex's "ask unless you are sure
/// it is safe", and under `exec` there is nobody to ask, so it refuses what it
/// won't run unattended and prints why. That refusal now reaches the chat in
/// Codex's own words.
///
/// Codex still judges the trivial cases itself — a bare `echo` never stops for
/// anyone — so copy must not promise otherwise.
({String policy, String sandbox}) codexApprovalPolicy(AgentApprovalMode mode) =>
    switch (mode) {
      // Nothing to approve, because nothing may be touched.
      AgentApprovalMode.readOnly => (policy: 'never', sandbox: 'read-only'),
      // The planning turn is forced read-only by the sender, so this is only
      // ever the turn that carries a plan out.
      AgentApprovalMode.plan || AgentApprovalMode.ask => (
        policy: 'untrusted',
        sandbox: 'workspace-write',
      ),
      AgentApprovalMode.full => (
        policy: 'never',
        sandbox: 'danger-full-access',
      ),
    };
