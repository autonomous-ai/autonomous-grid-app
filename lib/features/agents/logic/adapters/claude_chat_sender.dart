import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/cli/agent_event.dart';
import '../../../../infrastructure/cli/agent_resume_point.dart';
import '../../../../infrastructure/cli/chrome_bridge_service.dart';
import '../../../../infrastructure/cli/chrome_extension_probe.dart';
import '../../../../infrastructure/cli/command_log.dart';
import '../../../../infrastructure/cli/raw_agent_argv.dart';
import '../../../../infrastructure/cli/raw_agent_service.dart';
import '../../../../infrastructure/logging/app_log.dart';
import '../../../../infrastructure/mcp/grid_mcp_provider.dart';
import '../../../../infrastructure/state/chat_prefs_store.dart';
import '../../../../infrastructure/state/models/network_credential.dart';
import '../../../../shared/copy/setup_hints.dart';
import '../../../network/logic/app_guide_snippets.dart';
import '../../../playground/logic/chat_message.dart';
import '../../../playground/logic/chat_sender.dart';
import '../../../playground/logic/playground_request.dart';
import '../agent_catalog.dart';
import '../agent_model_support.dart';
import '../agent_prompt.dart';
import '../agent_providers.dart';
import '../agent_turn_log.dart';
import '../model_context_window.dart';
import 'agent_turn_env.dart';
import 'claude_browser.dart';
import 'claude_tool.dart';
import 'claude_turn_mcp_config.dart';
import 'raw_turn_stream.dart';

/// Claude Code's own `/goal`, which the app delegates to rather than running a
/// second, weaker loop beside it — see [GoalOwner].
///
/// It is checked against the installed binary (`supportsNonInteractive: true`)
/// rather than assumed, because an unrecognised `/name` is taken as literal
/// prompt text: the goal would simply never be set, and the turn would look like
/// it worked.
const String kClaudeGoalCommand = '/goal';

/// The one word that ends a Claude Code goal.
///
/// **Not** `kGoalClearWords`. Measured on 2.1.233: `/goal off` and `/goal none`
/// do not clear — they are read as an empty condition and answer "No goal set",
/// leaving the goal armed and every later turn still captured by it. Only
/// `clear` works, so the app's six friendly words stop at its own loop.
const String kClaudeGoalClear = '/goal clear';

/// Run one of Claude Code's own commands against a session, changing that
/// session and **nothing else**.
///
/// Pausing or clearing a goal is not a turn: it says nothing, it asks nothing,
/// and it must leave no trace in the conversation. Routed through `send()` it
/// left two messages behind every time — the sentence the app made up to carry
/// the command, and the CLI's "Goal cleared: …" answering it — so a chat the
/// user paused twice read like an argument with itself.
///
/// **TODO(BE): this is now mostly a no-op, and says so loudly rather than
/// quietly.** It needs a session id, and a raw turn never learns one — that came
/// out of the JSON stream's opening line. So it only fires for a chat whose
/// [AgentResumePoint] was written by something else (an imported session), and
/// for every other chat a paused goal is cleared app-side while Claude Code's own
/// copy stays armed inside the next `--resume`-less turn. In practice the goal
/// simply doesn't survive a turn either, since nothing resumes.
///
/// Best effort by design. Every failure path returns quietly: the app-side state
/// has already been recorded by the caller, and a command that could not be
/// delivered must not also throw away what the user asked for.
Future<void> runClaudeSessionCommand(
  Ref ref, {
  required AgentResumePoint? resume,
  required String model,
  required String command,
}) async {
  final service = ref.read(claudeServiceProvider);
  final log = ref.read(appLogProvider);
  if (service == null || resume == null) return;
  if (resume.agent != AgentTool.claude.id) return;
  final workdir = resume.workdir ?? ref.read(agentWorkspaceDirProvider).path;
  try {
    final run = service.run(
      workdir: workdir,
      prompt: command,
      args: claudeRawArgs(
        model: model,
        approval: AgentApprovalMode.readOnly,
        resumeSessionId: resume.sessionId,
      ),
    );
    // Read to the end so the process isn't left writing into a full pipe; the
    // words themselves belong to nobody here.
    await run.output.drain<void>();
    await run.done;
    log.info('agent', 'ran $command on the session');
  } on Object catch (error) {
    log.failure('agent', "couldn't run $command on the session: $error");
  }
}

/// The Claude Code seam, or null when Claude Code is absent.
final claudeServiceProvider = Provider<RawAgentService?>((ref) {
  final path = ref.watch(claudePathProvider);
  return path == null ? null : RawAgentServiceImpl(path);
});

/// A [ChatSender] backed by `claude -p` — Claude Code's own text mode, printed
/// into the chat exactly as it comes.
///
/// **Nothing is parsed.** This lane used to run `--output-format stream-json` and
/// read the events out of it, and that is where everything the chat drew came
/// from: the activity feed, the plan, the questions, the file changes behind the
/// Open button, the session id a later turn resumed from, the running token count
/// that decided when to compact, and the `--permission-prompt-tool` channel the
/// approval cards were answered on. The CLI serves that channel *only* alongside
/// stream-json, so none of it survives here (see [claudePermissionArgs] for what
/// the composer's modes now mean).
///
/// With no session to resume, every turn starts a fresh `claude` and replays the
/// conversation into the prompt ([buildAgentPrompt]), capped at
/// [kAgentTranscriptBudget]. Compaction went with it — there is no session to
/// summarize, and the transcript budget is the ceiling instead.
///
/// What still holds, because none of it was ever parsed out of the reply: the
/// grid the turn answers on ([claudeCodeEnv]), the connectors and Grid's own
/// tools it can reach ([ClaudeTurnMcpConfig]), the browser lane, and the
/// schedulers taken away from every turn ([kClaudeSessionSchedulerTools]).
final claudeChatSenderProvider = Provider<ChatSender>(ClaudeChatSender.new);

/// Sends one chat turn to `claude -p` and streams back what it printed.
class ClaudeChatSender implements ChatSender {
  ClaudeChatSender(this._ref);

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
    String? agentCommand,
    bool planFirst = false,
    AgentApprovalMode? approval,
    // Nothing to resume: a text-mode turn never learns Claude Code's session id,
    // so every turn is a fresh one carrying the transcript in its prompt.
    AgentResumePoint? resume,
  }) async* {
    if (modality != PlaygroundModality.text) {
      yield const ChatSendFailure('The agent can only answer in text.');
      return;
    }
    if (_ref.read(claudeServiceProvider) == null) {
      yield ChatSendFailure(notSetUpToMessage('answer chats'));
      return;
    }
    if (history.isEmpty || history.last.text.trim().isEmpty) {
      yield const ChatSendFailure('Nothing to send.');
      return;
    }

    // The live run belongs to whatever answered last. Cleared so a Hermes turn's
    // steps can't linger under a Claude answer that publishes none of its own.
    final chat = conversationId ?? '';
    _ref.read(agentRunsProvider.notifier).reset(chat);

    // This turn runs under the mode its *chat* was set to when Send was pressed.
    // Plan mode has two shapes: the planning turn is forced read-only, and the
    // execute turn that follows an approval carries the plan out.
    final chosen = approval ?? _ref.read(chatPrefsProvider).approval;
    final mode = planFirst
        ? AgentApprovalMode.readOnly
        : (chosen == AgentApprovalMode.plan ? AgentApprovalMode.ask : chosen);

    final root = workdir ?? _ref.read(agentWorkspaceDirProvider).path;

    // A command the CLI runs itself goes out as the whole prompt, verbatim. All
    // three wrappers below would bury it — the replayed transcript, the project's
    // standing rules, Plan mode's preamble — and a `/goal` that is not the first
    // thing in the prompt is read as words, so the goal is silently never set
    // while the turn looks like it worked. See [ChatSender.send].
    final command = agentCommand?.trim();
    final replay = buildAgentPrompt(history);
    final prompt = command != null && command.isNotEmpty
        ? command
        : withProjectInstructions(
            planFirst ? withPlanPreamble(replay) : replay,
            instructions,
          );

    // How much of the model Claude Code may fill before it summarizes — what the
    // grid advertises, what an engine taught, or the assumption the app falls
    // back on. See [modelContextWindowProvider].
    final window = _ref.read(modelContextWindowProvider(model));

    // Which browser this turn can reach, if any — decided per turn because the
    // answer moves between two messages: the user installs the extension,
    // restarts Chrome, or switches to a model the extension can't serve.
    final browser = await _openBrowser(model);
    final onExtension = browser.lane == ClaudeBrowserLane.extension;

    // Rewritten per turn, not cached: a connector signed in or disconnected since
    // the last message has to be in — or out of — this one. Null when the write
    // failed, which launches the turn on `~/.claude.json` rather than on a path
    // `claude` would reject. Grid's own tools ride in `extra` rather than in that
    // file: the user's file is theirs, and an entry naming a port this process
    // happens to be holding would outlive the session that made it true.
    final grid = _ref.read(gridMcpServerProvider);
    await grid.start();
    final gridUrl = grid.url;
    final mcpConfigPath = await ClaudeTurnMcpConfig().write(
      extra: {
        ...browser.mcpExtra,
        // No chat, no tools: `grid_ask` is answered *into* a conversation, and a
        // turn that belongs to none has nowhere to start a loop.
        if (gridUrl != null && conversationId != null)
          'grid': gridMcpServerEntry(
            url: gridUrl,
            token: grid.mintTurnToken(conversationId),
          ),
      },
    );

    // On the extension lane Claude Code runs against its own sign-in, where the
    // relay's name for the seat (`claude:opus`) is not a model it knows.
    final turnModel = onExtension ? claudeLocalModel(model) : model;
    final environment = {
      // On both lanes: it says which chat this turn is in, which has nothing to
      // do with who serves the model.
      ...gridTurnEnv(conversationId),
      ...onExtension
          ? const <String, String>{}
          : claudeCodeEnv(
              network.relayBaseUrl,
              network.relayApiKey,
              [model],
              // Null below Claude Code's own floor of 100000, where the value
              // would be discarded and 100000 used instead — see
              // [claudeCompactWindow].
              compactWindow: claudeCompactWindow(agentContextCeiling(window)),
              // Claude Code reserves 32000 output tokens by default — more than a
              // grid model's window can spare above the ceiling, and the reply
              // alone drew the 400 (#47). Sized to what *this* model's ceiling
              // leaves room for.
              maxOutputTokens: agentReplyReserve(window),
              // A chat turn, so the ~922 KB reference for Anthropic's API — and
              // every other bundle that could grow to match it — stays out of a
              // window this turn needs for the conversation.
              withoutBundledSkills: true,
            ),
    };

    yield* _runTurn(
      workdir: root,
      prompt: prompt,
      model: turnModel,
      approval: mode,
      environment: environment,
      dropEnvironment: onExtension ? kClaudeRelayEnvKeys : const <String>{},
      mcpConfigPath: mcpConfigPath,
      chrome: onExtension,
      // Whether to take away Claude Code's server-side web tools for this turn.
      // They are the provider's to run, so whatever answers the request has to
      // understand them. On the extension lane that is Anthropic itself; on a
      // `claude:*` seat it is Claude Code behind the relay — both keep them. A
      // grid model does not: the relay refuses the **whole request**, so asking
      // for today's weather spent a step on `400 Unsupported tool type:
      // web_search_20250305` before the agent fell back to the `grid-web` skill.
      withoutServerWebTools: !onExtension && !isClaudeSeatModel(model),
    );
  }

  /// The browser lane this turn takes, with the fallback browser already started
  /// if that is the lane — so the caller gets a lane it can act on rather than a
  /// promise that may not hold.
  ///
  /// Every outcome is logged, including the ones that take no browser at all:
  /// "the agent didn't use my browser" is the report this feature generates, and
  /// the log is the only place that can answer it (§6).
  ///
  /// TODO(BE): whether the extension's MCP server actually *connected* was read
  /// off the JSON stream's opening line and is no longer knowable — a turn can
  /// carry `--chrome`, report the lane here, and still hold no browser tools at
  /// all. The only symptom left is an agent that talks about the browser and
  /// never opens it.
  Future<({ClaudeBrowserLane lane, Map<String, Object?> mcpExtra})>
  _openBrowser(String model) async {
    final log = _ref.read(appLogProvider);
    final plan = planClaudeBrowser(
      model: model,
      extensionState: _ref.read(chromeExtensionProbeProvider).detect(),
      cliSupportsChrome: await _ref.read(claudeSupportsChromeProvider.future),
      cdpReady: _ref.read(chromeBridgeAvailableProvider),
      cdpAllowed: _ref.read(chatPrefsProvider).agentBrowser,
    );
    if (plan.lane != ClaudeBrowserLane.cdp) {
      log.info('agent', 'Browser lane ${plan.lane.name}: ${plan.reason}');
      return (lane: plan.lane, mcpExtra: const <String, Object?>{});
    }

    final url = await _ref.read(chromeBridgeProvider).ensureRunning();
    final npx = _ref.read(npxPathProvider);
    if (url == null || npx == null) {
      log.failure(
        'agent',
        "Browser lane none: the app's own browser wouldn't start "
            '(${plan.reason})',
      );
      return (
        lane: ClaudeBrowserLane.none,
        mcpExtra: const <String, Object?>{},
      );
    }
    log.info('agent', 'Browser lane cdp on $url: ${plan.reason}');
    return (
      lane: plan.lane,
      mcpExtra: {
        kChromeDevtoolsServerName: chromeDevtoolsEntry(
          npxPath: npx,
          browserUrl: url,
        ),
      },
    );
  }

  /// Run one turn and stream its output into the bubble as it lands.
  Stream<ChatSendUpdate> _runTurn({
    required String workdir,
    required String prompt,
    required String model,
    required AgentApprovalMode approval,
    required Map<String, String> environment,
    required Set<String> dropEnvironment,
    required String? mcpConfigPath,
    required bool chrome,
    required bool withoutServerWebTools,
  }) {
    final log = _ref.read(commandLogProvider.notifier);
    // The same builder the run is given — a wrong flag fails exactly like a
    // model that wouldn't answer, so the argv belongs on screen (§7).
    final args = claudeRawArgs(
      model: model,
      approval: approval,
      mcpConfigPath: mcpConfigPath,
      chrome: chrome,
      withoutServerWebTools: withoutServerWebTools,
    );
    final logId = log.begin(
      CliCallKind.start,
      'claude -p -m $model (agent)',
      detail: agentTurnDetail(
        args: [claudeExecutable, ...args],
        workdir: workdir,
        environment: environment,
        prompt: prompt,
      ),
    );

    return streamRawAgentTurn(
      run: _ref
          .read(claudeServiceProvider)!
          .run(
            workdir: workdir,
            prompt: prompt,
            args: args,
            environment: environment,
            dropEnvironment: dropEnvironment,
          ),
      log: log,
      logId: logId,
      agentName: 'Claude Code',
    );
  }
}
