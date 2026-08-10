import '../../provider_node/logic/api_engine_catalog.dart';
import 'agent_catalog.dart';

/// The kind a Claude Code seat's models carry before the colon
/// (`claude:opus`) — the CLI's own service kind, mirroring [kApiProviders].
const String kClaudeSeatKind = 'claude';

/// The kinds a Codex seat's models carry: the ChatGPT subscription seat
/// (`codex:*`, responses-only) and the Codex CLI seat (`codex-cli:*`). Both are
/// OpenAI's CLI answering, whichever way it signed in.
const Set<String> kCodexSeatKinds = {'codex', 'codex-cli'};

/// Every CLI-seat kind — a vendor's own coding CLI answering behind the relay,
/// rather than a model a machine on the grid is serving.
const Set<String> kCliSeatKinds = {kClaudeSeatKind, ...kCodexSeatKinds};

/// Whether [tool] can answer a chat with [model].
///
/// A seat model **is** a vendor's own CLI answering behind the relay, and only
/// that vendor's agent can drive it. Pairing it with any other agent doesn't
/// degrade — it dead-ends at the relay with "No machine on this grid is serving
/// a model Codex can use right now", a wall the user only meets *after* sending,
/// on a pair the composer offered them.
///
/// Everything else — a gguf on someone's machine, `auto`, a key provider's model
/// — answers plain chat-completions and is open to all three agents.
bool agentSupportsModel(AgentTool tool, String model) => switch (tool) {
  // Codex speaks the Responses API; a Claude seat answers Anthropic messages and
  // chat-completions, so the relay has nobody to hand a Codex turn to.
  AgentTool.codex => !_namesKind(model, const {kClaudeSeatKind}),
  // Claude Code speaks Anthropic's messages, which no Codex seat answers.
  AgentTool.claude => !_namesKind(model, kCodexSeatKinds),
  // Hermes drives neither vendor's CLI, and a seat can't take its agent turns:
  //
  //  - a `claude:*` seat answers Hermes's chat-completions call and can emit a
  //    `tool_calls` field — but under Hermes's real tool set it keeps ending the
  //    turn by *typing* the call out as prose with `finish_reason: stop`
  //    instead. Hermes reads a text response as the final answer and stops
  //    there, so the turn's whole output is the tool call. Measured 03/08 on
  //    three cron runs (`agent.log`: `tool_turns=0/1/6`, `response_len=470/256/
  //    10`); the same jobs on a grid model the same morning ended ~10,000 chars
  //    into a real report;
  //  - a `codex:*` seat fails twice over on the Hermes that ships today
  //    (measured 31/07, v0.19.0): the config it needs (`provider: grid` +
  //    `api_mode: codex_responses`) is a shape this build can't resolve
  //    (`session/new` refuses with "No LLM provider configured"), and pointed at
  //    the endpoint by a config it *does* resolve, its Responses client omits
  //    the `stream: true` / `store: false` the relay requires ("Invalid API
  //    response after 3 retries") — the same request with both flags answers in
  //    a second, so the seat is fine and the client isn't;
  //  - a `codex-cli:*` seat is the same shape as the Claude one — the vendor's
  //    coding CLI answering a single turn behind the relay — and is blocked with
  //    it rather than waiting to be measured on somebody's 8am task.
  AgentTool.hermes => !_namesKind(model, kCliSeatKinds),
  // Pi answers a grid model over OpenAI chat-completions, so any plain grid
  // model or `auto` is open to it. A CLI seat is the vendor's own coding CLI
  // answering behind the relay — Pi can't drive Claude Code, Codex or a Codex
  // CLI seat, so every seat is blocked, exactly as for Hermes.
  AgentTool.pi => !_namesKind(model, kCliSeatKinds),
};

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

/// Whether **everything** [model] names is a Claude Code seat (`claude:opus`) —
/// the vendor's own CLI answering behind the relay, rather than a model a
/// machine is serving.
///
/// The one question the browser lane turns on, and the reason it asks *every*
/// rather than *any*: only when the whole selection is a seat is the brain
/// behind the answer already Claude Code, so running it locally to reach the
/// browser extension changes the route without changing who answers. One grid
/// model in the list and the local run would quietly answer as somebody else.
bool isClaudeSeatModel(String model) =>
    _modelKinds(model).every((kind) => kind == kClaudeSeatKind);

/// Whether [model] names any of [kinds] before its colon. Reads the comma-joined
/// form (`qwen3, codex:gpt-5.5`) a multi-model selection carries too, so one
/// foreign model in a list can't slip past.
bool _namesKind(String model, Set<String> kinds) =>
    _modelKinds(model).any(kinds.contains);

/// The kind each name in [model] carries before its colon — `qwen3` for a plain
/// grid model, `claude` / `codex` for a seat.
Iterable<String> _modelKinds(String model) =>
    model.split(',').map((name) => name.trim().toLowerCase().split(':').first);
