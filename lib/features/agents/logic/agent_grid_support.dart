import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agent/agent_definition.dart';
import '../../agent/agent_registry.dart';
import '../../network/logic/grid_overview_provider.dart';

/// Whether [agent] can answer chats on a grid whose overview reports
/// [advertisesResponses].
///
/// Null reads as **"let it try"**, never as "no": the flag is null while the
/// overview loads, when it fails, and on every relay that doesn't ship it yet.
/// Treating unknown as unsupported would knock a Codex user back to Hermes for
/// the seconds before the overview lands — and permanently on an older grid.
bool agentRunsOnGrid(
  AgentDefinition agent, {
  required bool? advertisesResponses,
}) => !agent.needsResponses || advertisesResponses != false;

/// Why [agent] can't answer on the open grid, in the user's terms — no wire
/// dialects, no endpoint names, just the fact that decides it.
///
/// One sentence shared by the Agents row and the chat's notice: the two screens
/// state the same fact, and stating it twice in two wordings is how a user ends
/// up thinking they're two different problems.
String agentUnsupportedHere(AgentDefinition agent) =>
    "This grid doesn't serve a model ${agent.name} can talk to.";

/// What the selected grid's overview says about the Responses API: true/false
/// when the relay reports it, null before the first overview lands, when it
/// fails, or when the relay doesn't report it at all.
final gridAdvertisesResponsesProvider = Provider.autoDispose<bool?>(
  (ref) => ref.watch(gridOverviewSnapshot)?.advertisesResponses,
);

/// Whether the agent with [id] can answer chats on the grid selected right now.
///
/// A grid-level answer, from a grid-level flag: it says the grid serves *a*
/// model this agent can talk to, not that the model the user picked is that one.
/// A mismatch there surfaces as the send's own failure, not as a guess up front.
final agentRunsOnGridProvider = Provider.autoDispose.family<bool, String>((
  ref,
  id,
) {
  final agent = agentById(id);
  if (agent == null) return false;
  return agentRunsOnGrid(
    agent,
    advertisesResponses: ref.watch(gridAdvertisesResponsesProvider),
  );
});
