import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/grid_overview.dart';
import '../../network/logic/client_app_detector.dart';
import '../../network/logic/client_app_grid_support.dart';
import '../../network/logic/grid_overview_provider.dart';
import 'agent_catalog.dart';

/// The wire dialect [tool] needs the grid to answer on.
///
/// Three agents, three answers, and they are the same three a *client app*
/// needs — so this reads [clientDialect] rather than restating it: Hermes and
/// Claude Code are the same programs the how-to-use guide sets up by hand, and
/// two lists of which endpoint each one speaks is how the two screens end up
/// disagreeing about the same grid.
///
/// - **Codex** ≥ 0.141 rejects `wire_api = "chat"` outright, so it has nothing to
///   say to a grid that answers only on `/v1/chat/completions`.
/// - **Claude Code** speaks Anthropic's `/v1/messages`, which the relay has to
///   serve — a grid carrying a `claude:*` seat does.
/// - **Hermes** speaks both dialects — it switches to `api_mode: responses` on a
///   named provider when the model needs it (see `hermesConfigSnippet`) — so it
///   runs wherever a chat model does, and stays the agent that always has
///   somewhere to go.
RelayDialect agentDialect(AgentTool tool) => switch (tool) {
  AgentTool.codex => clientDialect(ClientApp.codex),
  AgentTool.claude => clientDialect(ClientApp.claudeCode),
  AgentTool.hermes => clientDialect(ClientApp.hermes),
  // Pi posts to `/v1/chat/completions` (its grid provider is an
  // `openai-completions` one), so — like Hermes — it runs wherever a chat model
  // does and always has somewhere to go.
  AgentTool.pi => RelayDialect.chatCompletions,
};

/// Whether [tool] can answer chats on a grid described by [overview].
///
/// An unreported flag reads as **"let it try"**, never as "no": it is null while
/// the overview loads, when it fails, and on every relay that doesn't ship it
/// yet. Treating unknown as unsupported would knock a Codex user back to Hermes
/// for the seconds before the overview lands — and permanently on an older grid.
bool agentRunsOnGrid(AgentTool tool, GridOverview? overview) =>
    gridAdvertises(agentDialect(tool), overview) != false;

/// Why [tool] can't answer on the open grid, in the user's terms — no wire
/// dialects, no endpoint names, just the fact that decides it.
///
/// One sentence shared by the Agents row, the chat's notice and the app guide
/// ([appUnsupportedHere]): those screens state the same fact, and stating it in
/// three wordings is how a user ends up thinking they're three problems.
String agentUnsupportedHere(AgentTool tool) => appUnsupportedHere(tool.name);

/// Whether [tool] can answer chats on the grid selected right now.
///
/// A grid-level answer, from a grid-level flag: it says the grid serves *a*
/// model this agent can talk to, not that the model the user picked is that one.
/// A mismatch there surfaces as the send's own failure, not as a guess up front.
final agentRunsOnGridProvider = Provider.autoDispose.family<bool, AgentTool>(
  (ref, tool) => agentRunsOnGrid(tool, ref.watch(gridOverviewSnapshot)),
);
