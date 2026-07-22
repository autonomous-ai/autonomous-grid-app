import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../network/logic/grid_overview_provider.dart';
import 'agent_catalog.dart';

/// Whether [tool] can only be reached over the Responses API.
///
/// Codex ≥ 0.141 rejects `wire_api = "chat"` outright, so it has nothing to say
/// to a grid that answers only on `/v1/chat/completions`. Hermes speaks both —
/// it switches to `api_mode: responses` on a named provider when the model needs
/// it (see `hermesConfigSnippet`) — so it runs wherever a chat model does, and
/// stays the agent that always has somewhere to go.
bool agentNeedsResponses(AgentTool tool) => switch (tool) {
  AgentTool.codex => true,
  AgentTool.hermes => false,
};

/// Whether [tool] can answer chats on a grid whose overview reports
/// [advertisesResponses].
///
/// Null reads as **"let it try"**, never as "no": the flag is null while the
/// overview loads, when it fails, and on every relay that doesn't ship it yet.
/// Treating unknown as unsupported would knock a Codex user back to Hermes for
/// the seconds before the overview lands — and permanently on an older grid.
bool agentRunsOnGrid(AgentTool tool, {required bool? advertisesResponses}) =>
    !agentNeedsResponses(tool) || advertisesResponses != false;

/// Why [tool] can't answer on the open grid, in the user's terms — no wire
/// dialects, no endpoint names, just the fact that decides it.
///
/// One sentence shared by the Agents row and the chat's notice: the two screens
/// state the same fact, and stating it twice in two wordings is how a user ends
/// up thinking they're two different problems.
String agentUnsupportedHere(AgentTool tool) =>
    "This grid doesn't serve a model ${tool.name} can talk to.";

/// What the selected grid's overview says about the Responses API: true/false
/// when the relay reports it, null while it loads, when it fails, or when the
/// relay doesn't report it at all.
final gridAdvertisesResponsesProvider = Provider.autoDispose<bool?>(
  (ref) => ref.watch(gridOverviewProvider).asData?.value.advertisesResponses,
);

/// Whether [tool] can answer chats on the grid selected right now.
///
/// A grid-level answer, from a grid-level flag: it says the grid serves *a*
/// model this agent can talk to, not that the model the user picked is that one.
/// A mismatch there surfaces as the send's own failure, not as a guess up front.
final agentRunsOnGridProvider = Provider.autoDispose.family<bool, AgentTool>(
  (ref, tool) => agentRunsOnGrid(
    tool,
    advertisesResponses: ref.watch(gridAdvertisesResponsesProvider),
  ),
);
