import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/subscription_model.dart';
import '../../../../infrastructure/logging/app_log.dart';
import '../../../../infrastructure/mcp/grid_mcp_provider.dart';
import '../../../../infrastructure/mcp/grid_mcp_server.dart';
import '../../../../infrastructure/state/models/network_credential.dart';
import '../../../network/logic/app_guide_snippets.dart';
import '../../../network/logic/network_models_provider.dart';
import '../model_context_window.dart';
import 'agent_turn_env.dart';
import 'claude_browser.dart';
import 'claude_turn_mcp_config.dart';

/// What a Claude Code run needs to answer on the app's grid, with the app's own
/// tools: the environment to start it in, and the MCP config to point it at.
///
/// [mcpToken] is the grant Grid's tools were handed, or null when the run got
/// none. A caller that opened a **session** owns it and must
/// [GridMcpServer.revoke] it when the session ends; a turn's is replaced by the
/// next turn's and can be forgotten.
typedef ClaudeGridSetup = ({
  Map<String, String> environment,
  Set<String> dropEnvironment,
  String? mcpConfig,
  String? mcpToken,
});

/// What a Codex run needs for the same: `-c` overrides for the command line, and
/// the key in the child's environment.
typedef CodexGridSetup = ({
  List<String> config,
  Map<String, String> environment,
  String? mcpToken,
});

/// Prepare a Claude Code run — one `-p` turn, or a whole terminal session.
///
/// Shared because it was written twice and is about to be written a third time,
/// and the copies are the kind that stop agreeing quietly: a grid handed over
/// in one lane and not the other looks exactly like a model that answers in the
/// chat and refuses in the terminal.
///
/// [relayEnv] false is a run that answers on **Claude Code's own sign-in** and
/// must not see the relay's credentials at all — the browser-extension lane,
/// which Claude Code closes to any API-key session, and the subscription model
/// ([subscriptionModelChosen]), which is that choice made on purpose. Leaving a
/// variable out of a map does not remove one already in the parent, so the names
/// to take away travel back in [ClaudeGridSetup.dropEnvironment] — the caller
/// hands them to whichever spawn it owns rather than working them out twice.
///
/// [turnId] is the one turn this run answers, when it is a turn at all — it
/// rides out as the request header the relay attributes every call to, so a
/// session (which is many turns) passes none. See [gridTurnEnv].
///
/// [mcpExtra] is merged into the turn's MCP config, for the servers only the
/// caller knows about (the browser). Grid's own tools are added here, on a token
/// minted for [conversationId] — no chat, no tools, because the token *is* the
/// chat (see `GridMcpServer`): it is what lets a turn's grant be retired with
/// the turn, and a run belonging to no chat has no turn to retire it with.
Future<ClaudeGridSetup> claudeGridSetup(
  Ref ref, {
  required NetworkCredential network,
  required String model,
  required String? conversationId,
  String? turnId,
  Map<String, Object?> mcpExtra = const {},
  bool relayEnv = true,
  bool session = false,
}) async {
  final grid = ref.read(gridMcpServerProvider);
  await grid.start();
  final url = grid.url;
  final token = _mcpToken(grid, conversationId, session: session);
  final mcpConfig = await ClaudeTurnMcpConfig().write(
    extra: {
      ...mcpExtra,
      if (url != null && token != null)
        'grid': gridMcpServerEntry(url: url, token: token),
    },
  );

  // How much of the model Claude Code may fill before it summarizes — what the
  // grid advertises, what an engine taught, or the assumption the app falls back
  // on. See [modelContextWindowProvider].
  final window = ref.read(modelContextWindowProvider(model));
  return (
    environment: {
      // On both lanes: it says which chat this run is in, which has nothing to
      // do with who serves the model.
      ...gridTurnEnv(conversationId, turnId: turnId),
      if (relayEnv)
        ...claudeCodeEnv(
          network.relayBaseUrl,
          network.relayApiKey,
          // The whole grid, so Claude Code's own `/model` lists what this grid
          // serves instead of the one model five times over — see
          // [claudeTierModel]. Empty while the list is still in flight (or the
          // grid is unreachable), which falls back to exactly what this passed
          // before: the run's own model in every slot.
          _gridModels(ref, model),
          // …while the run itself stays on the model the app started it with.
          pinned: model,
          // Null below Claude Code's own floor of 100000, where the value would
          // be discarded and 100000 used instead — see [claudeCompactWindow].
          compactWindow: claudeCompactWindow(agentContextCeiling(window)),
          // Claude Code reserves 32000 output tokens by default — more than a
          // grid model's window can spare above the ceiling, and the reply alone
          // drew the 400 (#47). Sized to what *this* model's ceiling leaves room
          // for.
          maxOutputTokens: agentReplyReserve(window),
        ),
    },
    dropEnvironment: relayEnv ? const <String>{} : kClaudeRelayEnvKeys,
    mcpConfig: mcpConfig,
    mcpToken: token,
  );
}

/// The models this grid serves, or just [model] when the list isn't there.
///
/// Read rather than watched, and never awaited: this runs in front of a turn
/// the user is waiting on, and a menu that lists one model is a far smaller
/// cost than a turn that waits on a round trip to fill it. `servedModelIds`
/// keeps the last answer across a refresh for exactly this kind of reader.
List<String> _gridModels(Ref ref, String model) {
  final served = ref.read(servedModelIdsProvider);
  return served.isEmpty ? [model] : served;
}

/// The grant Grid's tools run under for one agent run, or null when this run has
/// no chat to speak for — the token is the chat, and a run belonging to none has
/// no turn or session for its grant to live and die with.
///
/// Null is the whole answer, and the caller must then **not register the server
/// either**. Handing Codex `mcp_servers.grid` with no token behind it is what
/// produced `UnexpectedServerResponse("HTTP 401: ")` and killed its MCP
/// transport for the rest of the run.
String? _mcpToken(
  GridMcpServer grid,
  String? conversationId, {
  required bool session,
}) {
  if (conversationId == null) return null;
  return session
      ? grid.mintSessionToken(conversationId)
      : grid.mintTurnToken(conversationId);
}

/// Prepare a Codex run — one `exec` turn, or a whole terminal session.
///
/// The grid rides on the command line as `-c` overrides and the key rides in the
/// child's environment, so **nothing of the user's `~/.codex/config.toml` is
/// written**. This used to rewrite it, which changed the default model and
/// provider for every Codex session on the machine.
///
/// Codex flies blind on a grid model without the window: its bundled catalog
/// only carries the `gpt-5.*` slugs, so a grid id has no window in it at all and
/// it summarizes on a default it picked for a model it isn't talking to. Only
/// sent when a source actually named a figure — see
/// [knownModelContextWindowProvider].
///
/// [relayEnv] false is the subscription model ([subscriptionModelChosen]): the
/// run answers on the user's own ChatGPT sign-in, so it carries neither the
/// grid's provider table nor its key, and names Codex's own provider instead
/// ([codexOwnAccountOverrides]). Grid's **tools** still go with it — they are
/// this app's, minted per run, and have nothing to do with who answers.
Future<CodexGridSetup> codexGridSetup(
  Ref ref, {
  required NetworkCredential network,
  required String model,
  required String? conversationId,
  String? turnId,
  bool relayEnv = true,
  bool session = false,
}) async {
  final grid = ref.read(gridMcpServerProvider);
  await grid.start();
  final url = grid.url;
  final token = _mcpToken(grid, conversationId, session: session);
  // The server and its token are one decision, not two: registering
  // `mcp_servers.grid` while `$GRID_MCP_TOKEN` is unset hands Codex an endpoint
  // it can only be refused by, and the refusal is fatal to its whole MCP
  // transport rather than to the one call.
  final tools = url != null && token != null;

  // Only ever asked about a grid model. On the user's own account Codex is
  // talking to a model out of its own catalog, which it has the window for.
  final window = relayEnv
      ? ref.read(knownModelContextWindowProvider(model))
      : null;
  // Codex says so itself — "Model metadata for <id> not found. Defaulting to
  // fallback metadata; this can degrade performance" — and on the `auto` router
  // it says so every session, because no source names a window for a model the
  // relay picks per turn. **Not a number to invent**: see
  // [knownModelContextWindowProvider] for why telling Codex a figure this app
  // guessed is worse than leaving it on its own default. What was missing was
  // this line: the CLI's warning had nothing on our side to match it against.
  if (window == null && relayEnv) {
    ref
        .read(appLogProvider)
        .info(
          'agent',
          'codex: no reported context window for "$model" — it will run on its '
              'own fallback metadata and say so',
        );
  }

  return (
    config: [
      if (relayEnv)
        ...codexGridOverrides(
          base: network.relayBaseUrl,
          model: model,
          contextWindow: window,
          compactAt: window == null ? null : agentContextCeiling(window),
        )
      else
        ...codexOwnAccountOverrides,
      // Grid's own tools, as `-c` overrides for this run alone. Codex has no
      // per-process lever for *skills* — `$CODEX_HOME/skills` is the only path
      // it reads and moving CODEX_HOME takes the user's login with it — so this
      // is the whole reason the cards became an MCP server.
      if (tools) ...gridMcpCodexOverrides(url: url),
    ],
    environment: {
      if (relayEnv) kCodexAppApiKeyEnv: network.relayApiKey,
      ...gridTurnEnv(conversationId, turnId: turnId),
      if (tools) kGridMcpTokenEnv: token,
    },
    mcpToken: token,
  );
}
