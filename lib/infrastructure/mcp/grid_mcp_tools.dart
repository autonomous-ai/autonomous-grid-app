/// The tools Grid offers its own agents, and what they do — the contract that
/// used to be a folder of skill cards in the user's home.
///
/// **Why this stopped being cards.** A card is a file, and every agent reads its
/// cards from one global folder: `~/.claude/skills`, `~/.codex/skills`,
/// `~/.hermes/skills`. Installing Grid therefore changed what a colleague saw in
/// their own terminal, in repos that have nothing to do with this app. Claude
/// Code and Hermes each have a per-process lever; **Codex has none** — its only
/// skills path is `$CODEX_HOME/skills`, and moving `CODEX_HOME` takes the user's
/// login with it.
///
/// MCP is the one channel all three take per process (`--mcp-config` for Claude
/// Code, `-c mcp_servers.…` for Codex, the profile's own config for Hermes), so
/// the contract travels with the turn and lands in nobody's home directory.
///
/// It is also a better shape than the fenced block it replaces: a tool call has
/// arguments the app can validate and refuse, where a ```grid-ask``` block was a
/// string the app had to find, parse and hope about.
library;

import '../../features/chat/logic/commands/chat_command.dart';

/// A tool as the MCP wire describes it: a name, the sentence that decides
/// whether the model ever reaches for it, and the shape of its arguments.
class GridMcpTool {
  const GridMcpTool({
    required this.name,
    required this.description,
    required this.schema,
  });

  final String name;

  /// What the model reads before deciding. Written like a skill's front-matter
  /// for the same reason: this sentence is the whole retrieval mechanism.
  final String description;

  /// JSON Schema for the arguments, sent verbatim in `tools/list`.
  final Map<String, Object?> schema;

  Map<String, Object?> toJson() => {
    'name': name,
    'description': description,
    'inputSchema': schema,
  };
}

/// Ask Grid to start or stop work that outlives the turn.
///
/// The replacement for the `grid-ask` block, and for the phrase matching before
/// it. Grid owns `/loop`, `/goal` and `/schedule` because an agent's own timers
/// die with the process answering the message — measured on 2026-08-21, a
/// sub-agent's transcript stops one millisecond before the reply that promised
/// its report.
const GridMcpTool kGridAskTool = GridMcpTool(
  name: 'grid_ask',
  description:
      'Ask Grid to run work that outlives this turn: repeat something '
      '(/loop), keep going until a condition holds (/goal), run at a time or '
      'on a schedule (/schedule), or stop one that is running (/loop stop, '
      '/goal clear). Use it whenever the user asks for any of those — in any '
      'language, however indirectly, whether or not they name a command. Your '
      'own timers, cron and background agents do not survive this turn; these '
      'do. Answer the user as well: this is not instead of replying.',
  schema: {
    'type': 'object',
    'properties': {
      'run': {
        'type': 'string',
        'description':
            'The command line, exactly as the user would type it — for example '
            '"/loop 45m look for new sources" or "/goal the tests pass". Keep '
            'the prompt in the user\'s own words and language; only the '
            'command itself is English.',
      },
    },
    'required': ['run'],
  },
);

/// Read one of Grid's guides — the bodies that used to be skill cards.
///
/// Same progressive disclosure a card gives: the topic list is cheap and always
/// present, the body arrives only when asked for.
const GridMcpTool kGridGuideTool = GridMcpTool(
  name: 'grid_guide',
  description:
      'Read how something works on this computer before doing it. Topics: '
      '"delegate" (sub-agents die with this turn unless you wait for them), '
      '"loop" (pacing a repeat Grid is already running), "host" (what this '
      'machine has instead of timeout/gh/rg), "chart" (drawing numbers in the '
      'chat). '
      'Cheaper to read one than to find out the hard way.',
  schema: {
    'type': 'object',
    'properties': {
      'topic': {
        'type': 'string',
        'enum': ['delegate', 'loop', 'host', 'chart'],
      },
    },
    'required': ['topic'],
  },
);

/// Everything the server advertises, in `tools/list` order.
const List<GridMcpTool> kGridMcpTools = [kGridAskTool, kGridGuideTool];

/// What a `grid_ask` call resolved to, or why it did not.
///
/// A sealed result rather than a thrown string: the caller has to answer the
/// agent either way, and an exhaustive switch is what stops a new failure mode
/// from being reported as a success.
sealed class GridAskOutcome {
  const GridAskOutcome();
}

/// The call named a command Grid will run.
class GridAskAccepted extends GridAskOutcome {
  const GridAskAccepted(this.call);

  final ChatCommandCall call;
}

/// The call named something Grid does not run this way, and the message says
/// what to do instead — it goes back to the agent as the tool's result.
class GridAskRefused extends GridAskOutcome {
  const GridAskRefused(this.message);

  final String message;
}

/// The commands an agent may ask for. Deliberately not every command the
/// composer takes: `/clear` and `/compact` belong to the person reading the
/// chat, and an assistant that could clear the transcript it is being judged on
/// has a way out of every hard turn.
const Set<ChatCommand> kAgentRunnableCommands = {
  ChatCommand.loop,
  ChatCommand.goal,
  ChatCommand.schedule,
};

/// Reads a `grid_ask` argument into the command Grid should run.
///
/// Pure, so the refusals are testable without a chat, a grid or a process — and
/// they are the interesting half: this is the boundary where an agent's wish
/// becomes something the app spends the user's tokens on.
GridAskOutcome readGridAsk(Object? arguments) {
  final run = switch (arguments) {
    final Map<String, Object?> map => map['run'],
    _ => null,
  };
  if (run is! String || run.trim().isEmpty) {
    return const GridAskRefused(
      'Nothing to run. Pass `run` as the command line, e.g. '
      '"/loop 30m check the build".',
    );
  }
  final call = parseChatCommand(run.trim());
  if (call == null) {
    return GridAskRefused(
      'Grid does not know "${run.trim()}". Ask for one of /loop, /goal or '
      '/schedule.',
    );
  }
  if (!kAgentRunnableCommands.contains(call.command)) {
    return GridAskRefused(
      '/${call.command.name} is the user\'s to type, not yours. You can ask '
      'for /loop, /goal or /schedule.',
    );
  }
  return GridAskAccepted(call);
}
