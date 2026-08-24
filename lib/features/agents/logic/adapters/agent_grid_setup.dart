import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/mcp/grid_mcp_provider.dart';
import '../../../../infrastructure/state/models/network_credential.dart';
import '../../../network/logic/app_guide_snippets.dart';
import '../model_context_window.dart';
import 'agent_turn_env.dart';
import 'claude_turn_mcp_config.dart';

/// What a Claude Code run needs to answer on the app's grid, with the app's own
/// tools: the environment to start it in, and the MCP config to point it at.
typedef ClaudeGridSetup = ({
  Map<String, String> environment,
  String? mcpConfig,
});

/// What a Codex run needs for the same: `-c` overrides for the command line, and
/// the key in the child's environment.
typedef CodexGridSetup = ({
  List<String> config,
  Map<String, String> environment,
});

/// Prepare a Claude Code run — one `-p` turn, or a whole terminal session.
///
/// Shared because it was written twice and is about to be written a third time,
/// and the copies are the kind that stop agreeing quietly: a grid handed over
/// in one lane and not the other looks exactly like a model that answers in the
/// chat and refuses in the terminal.
///
/// [relayEnv] false is the browser-extension lane, where Claude Code runs against
/// its own sign-in and must not see the relay's credentials at all. The caller
/// still has to *drop* what this process inherited ([kClaudeRelayEnvKeys]) —
/// leaving a variable out of a map does not remove one already in the parent.
///
/// [mcpExtra] is merged into the turn's MCP config, for the servers only the
/// caller knows about (the browser). Grid's own tools are added here, on a token
/// minted for [conversationId] — no chat, no tools, because `grid_ask` is
/// answered *into* a conversation and a run belonging to none has nowhere to
/// put an answer.
Future<ClaudeGridSetup> claudeGridSetup(
  Ref ref, {
  required NetworkCredential network,
  required String model,
  required String? conversationId,
  Map<String, Object?> mcpExtra = const {},
  bool relayEnv = true,
}) async {
  final grid = ref.read(gridMcpServerProvider);
  await grid.start();
  final url = grid.url;
  final mcpConfig = await ClaudeTurnMcpConfig().write(
    extra: {
      ...mcpExtra,
      if (url != null && conversationId != null)
        'grid': gridMcpServerEntry(
          url: url,
          token: grid.mintTurnToken(conversationId),
        ),
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
      ...gridTurnEnv(conversationId),
      if (relayEnv)
        ...claudeCodeEnv(
          network.relayBaseUrl,
          network.relayApiKey,
          [model],
          // Null below Claude Code's own floor of 100000, where the value would
          // be discarded and 100000 used instead — see [claudeCompactWindow].
          compactWindow: claudeCompactWindow(agentContextCeiling(window)),
          // Claude Code reserves 32000 output tokens by default — more than a
          // grid model's window can spare above the ceiling, and the reply alone
          // drew the 400 (#47). Sized to what *this* model's ceiling leaves room
          // for.
          maxOutputTokens: agentReplyReserve(window),
          // The ~922 KB reference for Anthropic's API — and every other bundle
          // that could grow to match it — stays out of a window this run needs
          // for the conversation. Grid's own skills live elsewhere.
          withoutBundledSkills: true,
        ),
    },
    mcpConfig: mcpConfig,
  );
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
Future<CodexGridSetup> codexGridSetup(
  Ref ref, {
  required NetworkCredential network,
  required String model,
  required String? conversationId,
}) async {
  final grid = ref.read(gridMcpServerProvider);
  await grid.start();
  final url = grid.url;
  final window = ref.read(knownModelContextWindowProvider(model));
  return (
    config: [
      ...codexGridOverrides(
        base: network.relayBaseUrl,
        model: model,
        contextWindow: window,
        compactAt: window == null ? null : agentContextCeiling(window),
      ),
      // Grid's own tools, as `-c` overrides for this run alone. Codex has no
      // per-process lever for *skills* — `$CODEX_HOME/skills` is the only path
      // it reads and moving CODEX_HOME takes the user's login with it — so this
      // is the whole reason the cards became an MCP server.
      if (url != null) ...gridMcpCodexOverrides(url: url),
    ],
    environment: {
      kCodexAppApiKeyEnv: network.relayApiKey,
      ...gridTurnEnv(conversationId),
      if (url != null && conversationId != null)
        kGridMcpTokenEnv: grid.mintTurnToken(conversationId),
    },
  );
}
