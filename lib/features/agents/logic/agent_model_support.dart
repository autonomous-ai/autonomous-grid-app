import '../../provider_node/logic/api_engine_catalog.dart';
import 'agent_catalog.dart';

/// The kind a Claude Code seat's models carry before the colon
/// (`claude:opus`) — the CLI's own service kind, mirroring [kApiProviders].
const String kClaudeSeatKind = 'claude';

/// The kinds a Codex seat's models carry: the ChatGPT subscription seat
/// (`codex:*`, responses-only) and the Codex CLI seat (`codex-cli:*`). Both are
/// OpenAI's CLI answering, whichever way it signed in.
const Set<String> kCodexSeatKinds = {'codex', 'codex-cli'};

/// Whether [tool] can answer a chat with [model].
///
/// A seat model **is** a vendor's own CLI answering behind the relay, so the
/// other vendor's CLI has nothing to say to it. Pairing them doesn't degrade —
/// it dead-ends at the relay with "No machine on this grid is serving a model
/// Codex can use right now", a wall the user only meets *after* sending, on a
/// pair the composer offered them.
///
/// Everything else — a gguf on someone's machine, `auto`, a key provider's model
/// — answers plain chat-completions and is open to all three agents.
bool agentSupportsModel(AgentTool tool, String model) => switch (tool) {
  // Codex speaks the Responses API; a Claude seat answers Anthropic messages and
  // chat-completions, so the relay has nobody to hand a Codex turn to.
  AgentTool.codex => !_namesKind(model, const {kClaudeSeatKind}),
  // Claude Code speaks Anthropic's messages, which no Codex seat answers.
  AgentTool.claude => !_namesKind(model, kCodexSeatKinds),
  // Hermes takes every model: it speaks chat-completions, and switches to the
  // Responses dialect on a named provider when the model needs it (`api_mode:
  // codex_responses` — see `hermesConfigSnippet`), so no seat is closed to it.
  //
  // It used to be refused a responses-only model, because Hermes v0.19.0
  // answered that config with "Unknown provider 'grid'" and died. That was a
  // build being too old for a connection the app writes correctly, not a pair
  // that can't work — so the app offers it and says so if a build still can't
  // (see [friendlyAgentUnknownProvider]) rather than closing the road for
  // everyone.
  AgentTool.hermes => true,
};

/// The agents that can answer with [model], in catalog order — who the user can
/// switch to when the one in force can't.
List<AgentTool> agentsForModel(String model) => [
  for (final tool in AgentTool.values)
    if (agentSupportsModel(tool, model)) tool,
];

/// The mark on a model row the agent in force can't use — short, because it
/// rides beside the model's own name.
String agentModelBlockedLabel(AgentTool tool) => 'Not for ${tool.name}';

/// The whole sentence behind that mark: what won't work and what to do about it.
///
/// It names no replacement agent. Which one to switch to depends on the model,
/// and the assistant picker sits right beside this row wearing the answer — a
/// sentence that guessed for the user would be wrong on half the grids.
String agentModelBlockedReason(AgentTool tool) =>
    "${tool.name} can't answer with this model. Switch the assistant to use it.";

/// Whether [model] names any of [kinds] before its colon. Reads the comma-joined
/// form (`qwen3, codex:gpt-5.5`) a multi-model selection carries too, so one
/// foreign model in a list can't slip past.
bool _namesKind(String model, Set<String> kinds) => model
    .split(',')
    .map((name) => name.trim().toLowerCase().split(':').first)
    .any(kinds.contains);
