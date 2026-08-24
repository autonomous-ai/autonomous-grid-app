import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/cli/agent_event.dart';
import '../../../../infrastructure/cli/agent_resume_point.dart';
import '../../../../infrastructure/cli/command_log.dart';
import '../../../../infrastructure/cli/raw_agent_argv.dart';
import '../../../../infrastructure/cli/raw_agent_service.dart';
import '../../../../infrastructure/mcp/grid_mcp_provider.dart';
import '../../../../infrastructure/state/chat_prefs_store.dart';
import '../../../../infrastructure/state/models/network_credential.dart';
import '../../../../shared/copy/setup_hints.dart';
import '../../../network/logic/app_guide_snippets.dart';
import '../../../playground/logic/chat_message.dart';
import '../../../playground/logic/chat_sender.dart';
import '../../../playground/logic/playground_request.dart';
import '../agent_prompt.dart';
import '../agent_providers.dart';
import '../agent_turn_log.dart';
import '../model_context_window.dart';
import 'agent_turn_env.dart';
import 'codex_tool.dart';
import 'raw_turn_stream.dart';

/// The Codex seam, or null when Codex is absent.
final codexServiceProvider = Provider<RawAgentService?>((ref) {
  final path = ref.watch(codexPathProvider);
  return path == null ? null : RawAgentServiceImpl(path);
});

/// A [ChatSender] backed by `codex exec` — Codex's own text mode, printed into
/// the chat exactly as it comes.
///
/// **Nothing is parsed.** This lane used to drive `codex app-server` and read its
/// JSON-RPC: that is what drew the tool steps, the plan, the Open button behind a
/// file Codex wrote, and the approval cards. All of it went with the JSON, along
/// with the thread id a later turn resumed from — so every turn now starts a
/// fresh Codex and replays the conversation into the prompt
/// ([buildAgentPrompt]), capped at [kAgentTranscriptBudget].
///
/// What the user sees is `codex exec`'s own transcript: its header, its
/// working-out, its answer, and anything it wrote to stderr, in arrival order.
///
/// The grid it answers with is still handed over **per run** — `-c` overrides on
/// the command line, the key in the child process's environment
/// ([codexGridOverrides]) — and nothing of the user's is written, so their
/// terminal `codex` keeps answering with whatever *they* pointed it at.
///
/// **How much it may touch is still the chat's setting**, through the sandbox
/// ([codexApprovalPolicy]) — but "ask first" can no longer ask: `exec` has nobody
/// to put a card in front of, so it refuses what it won't run unattended and
/// prints why, and that refusal is what lands in the bubble.
final codexChatSenderProvider = Provider<ChatSender>(CodexChatSender.new);

/// Sends one chat turn to `codex exec` and streams back what it printed.
class CodexChatSender implements ChatSender {
  CodexChatSender(this._ref);

  final Ref _ref;

  @override
  Stream<ChatSendUpdate> send({
    required NetworkCredential network,
    required String model,
    required List<ChatMessage> history,
    PlaygroundModality modality = PlaygroundModality.text,
    List<MediaAttachment> attachments = const [],
    String? localBaseUrl,
    String? workdir,
    String? conversationId,
    String? instructions,
    // TODO(BE): Codex has thread goals over `thread/goal/set|get|clear`, not a
    // slash command on the wire — see GoalOwner.codex. Not supported yet.
    String? agentCommand,
    bool planFirst = false,
    AgentApprovalMode? approval,
    // Nothing to resume: a text-mode turn never learns Codex's thread id, so
    // every turn is a fresh one carrying the transcript in its prompt.
    AgentResumePoint? resume,
  }) async* {
    if (modality != PlaygroundModality.text) {
      yield const ChatSendFailure('The agent can only answer in text.');
      return;
    }
    if (_ref.read(codexServiceProvider) == null) {
      yield ChatSendFailure(notSetUpToMessage('answer chats'));
      return;
    }
    if (history.isEmpty || history.last.text.trim().isEmpty) {
      yield const ChatSendFailure('Nothing to send.');
      return;
    }

    // The live run belongs to whatever answered last. Cleared so a Hermes turn's
    // steps can't linger under a Codex answer that publishes none of its own.
    final chat = conversationId ?? '';
    _ref.read(agentRunsProvider.notifier).reset(chat);

    // This turn runs under the mode its *chat* was set to when Send was pressed.
    // Plan mode has two shapes, as it does for every agent: the planning turn is
    // forced read-only, and the execute turn that follows carries the plan out.
    final chosen = approval ?? _ref.read(chatPrefsProvider).approval;
    final mode = planFirst
        ? AgentApprovalMode.readOnly
        : (chosen == AgentApprovalMode.plan ? AgentApprovalMode.ask : chosen);

    // Only a figure something actually reported — never the assumption. See
    // [knownModelContextWindowProvider] for why this lane wants the nullable one.
    final contextWindow = _ref.read(knownModelContextWindowProvider(model));
    final root = workdir ?? _ref.read(agentWorkspaceDirProvider).path;

    // Grid's tools for this turn. Started here rather than at launch so a run
    // that never reaches an agent never opens a socket.
    final gridMcp = _ref.read(gridMcpServerProvider);
    await gridMcp.start();
    final gridMcpUrl = gridMcp.url;

    // The whole conversation, every turn: with no thread to resume there is no
    // "what it has already seen" to send only the rest of.
    final replay = buildAgentPrompt(history);
    final prompt = withProjectInstructions(
      planFirst ? withPlanPreamble(replay) : replay,
      instructions,
    );

    yield* _runTurn(
      workdir: root,
      prompt: prompt,
      model: model,
      approval: mode,
      // The grid rides on this run's own command line, and its key in the child
      // process's environment. Codex flies blind on a grid model otherwise: its
      // bundled catalog only carries the `gpt-5.*` slugs, so a grid id has no
      // window in it at all and it summarizes on a default it picked for a model
      // it isn't talking to.
      config: [
        ...codexGridOverrides(
          base: network.relayBaseUrl,
          model: model,
          contextWindow: contextWindow,
          compactAt: contextWindow == null
              ? null
              : agentContextCeiling(contextWindow),
        ),
        // Grid's own tools, as `-c` overrides for this run alone. Codex has no
        // per-process lever for *skills* — `$CODEX_HOME/skills` is the only path
        // it reads and moving CODEX_HOME takes the user's login with it — so
        // this is the whole reason the cards became an MCP server.
        if (gridMcpUrl != null) ...gridMcpCodexOverrides(url: gridMcpUrl),
      ],
      environment: {
        kCodexAppApiKeyEnv: network.relayApiKey,
        ...gridTurnEnv(conversationId),
        if (gridMcpUrl != null && conversationId != null)
          kGridMcpTokenEnv: gridMcp.mintTurnToken(conversationId),
      },
    );
  }

  /// Run one turn and stream its output into the bubble as it lands.
  Stream<ChatSendUpdate> _runTurn({
    required String workdir,
    required String prompt,
    required String model,
    required List<String> config,
    required Map<String, String> environment,
    required AgentApprovalMode approval,
  }) {
    final log = _ref.read(commandLogProvider.notifier);
    // The same builder the run is given — a wrong flag fails exactly like a
    // model that wouldn't answer, so the argv belongs on screen (§7).
    final args = codexRawArgs(
      model: model,
      workdir: workdir,
      approval: approval,
      config: config,
    );
    final logId = log.begin(
      CliCallKind.start,
      'codex exec -m $model (agent)',
      detail: agentTurnDetail(
        args: ['codex', ...args],
        workdir: workdir,
        environment: environment,
        prompt: prompt,
      ),
    );

    return streamRawAgentTurn(
      run: _ref
          .read(codexServiceProvider)!
          .run(
            workdir: workdir,
            prompt: prompt,
            args: args,
            environment: environment,
          ),
      log: log,
      logId: logId,
      agentName: 'Codex',
    );
  }
}
