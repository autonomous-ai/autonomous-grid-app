import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/cli/agent_event.dart';
import '../../../../infrastructure/cli/agent_resume_point.dart';
import '../../../../infrastructure/cli/claude_exec_event.dart';
import '../../../../infrastructure/cli/claude_exec_service.dart';
import '../../../../infrastructure/cli/claude_permission.dart';
import '../../../../infrastructure/cli/text_file.dart';
import '../../../../infrastructure/cli/chrome_bridge_service.dart';
import '../../../../infrastructure/cli/chrome_extension_probe.dart';
import '../../../../infrastructure/cli/command_log.dart';
import '../../../../infrastructure/logging/app_log.dart';
import '../../../../infrastructure/state/chat_prefs_store.dart';
import '../../../../infrastructure/state/model_context_store.dart';
import '../../../../infrastructure/state/models/network_credential.dart';
import '../../../../shared/copy/setup_hints.dart';
import '../../../network/logic/app_guide_snippets.dart';
import '../../../playground/logic/chat_message.dart';
import '../../../playground/logic/chat_sender.dart';
import '../../../playground/logic/playground_request.dart';
import '../agent_catalog.dart';
import '../agent_changes.dart';
import '../agent_model_support.dart';
import '../agent_prompt.dart';
import '../agent_providers.dart';
import '../agent_permission_decision.dart';
import '../agent_session_grants.dart';
import '../agent_permissions.dart';
import '../agent_server_error.dart';
import '../agent_session_slots.dart';
import '../agent_turn_log.dart';
import 'claude_browser.dart';
import 'claude_tool.dart';
import 'claude_turn_mcp_config.dart';
import '../model_context_window.dart';

/// Claude Code's own "summarize the conversation and keep the summary" command,
/// sent as a turn's whole prompt. Its definition inside the installed binary
/// carries `supportsNonInteractive: true`, which is what makes it usable from
/// `claude -p`; the CLI takes an unrecognised `/name` as literal prompt text, so
/// this is checked against the binary rather than assumed.
const String kClaudeCompactCommand = '/compact';

/// The activity-feed row a compaction runs under. Fixed, so the finished status
/// replaces the running one instead of adding a second row (`upsertStep` keys on
/// the id) — and so a chat that compacts twice doesn't grow two.
const String _compactStepId = 'compact-session';

/// The Claude Code exec seam, or null when Claude Code is absent.
final claudeExecServiceProvider = Provider<ClaudeExecService?>((ref) {
  final path = ref.watch(claudePathProvider);
  return path == null ? null : ClaudeExecServiceImpl(path);
});

/// A [ChatSender] backed by Claude Code over `claude -p`.
///
/// Claude runs one turn per process and exits, so — like Codex and unlike
/// Hermes's persistent ACP session — continuity comes from **resuming the
/// session**: the first turn replays the history and learns Claude's session id,
/// and each later turn sends only the new message with `--resume <id>`, letting
/// Claude hold the conversation context itself. Switching conversation, grid or
/// model starts a fresh session.
///
/// The grid is passed **in the child process's environment**, not by writing
/// `~/.claude/settings.json`. That file is the user's own — the app already
/// offers to write it from the how-to-use guide, deliberately and on request —
/// and quietly repointing it here would hijack every Claude Code session on this
/// computer, terminal ones included, for as long as the app felt like it.
///
/// It runs with **no sandbox** ([kClaudePermissionMode]): Claude changes files
/// and runs commands on this computer, and — unlike Hermes over ACP — `claude -p`
/// has no channel to ask first, so nothing here prompts the user. The approval
/// picker in the composer governs Hermes only; it has nothing to hand Claude.
/// TODO(BE): a per-action approval path for Claude would close that gap.
final claudeChatSenderProvider = Provider<ChatSender>(ClaudeChatSender.new);

class ClaudeChatSender implements ChatSender {
  ClaudeChatSender(this._ref);

  final Ref _ref;

  final _slots = AgentSessionSlots();

  /// [resume] when it is a Claude Code session opened in [root], else null.
  ///
  /// The id alone is not enough to act on. `claude --resume` takes any id it is
  /// handed, so a Codex id fails and — worse — the *right* id in the wrong
  /// folder succeeds, carrying on a conversation about files this turn isn't
  /// looking at.
  static AgentResumePoint? _adoptable(AgentResumePoint? resume, String root) {
    if (resume == null) return null;
    return resume.matches(thisAgent: AgentTool.claude.id, thisWorkdir: root)
        ? resume
        : null;
  }

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
    bool planFirst = false,
    AgentApprovalMode? approval,
    AgentResumePoint? resume,
  }) async* {
    if (modality != PlaygroundModality.text) {
      yield const ChatSendFailure('The agent can only answer in text.');
      return;
    }
    if (_ref.read(claudeExecServiceProvider) == null) {
      yield ChatSendFailure(notSetUpToMessage('answer chats'));
      return;
    }
    if (history.isEmpty || history.last.text.trim().isEmpty) {
      yield const ChatSendFailure('Nothing to send.');
      return;
    }

    // Everything this turn publishes is filed under its conversation, so two
    // chats answering at once never show each other's work. Cleared now, so the
    // chat's "working" bubble — already on screen — can't flash the previous
    // turn's steps. See [AgentRuns.reset].
    final chat = conversationId ?? '';
    _ref.read(agentRunsProvider.notifier).reset(chat);

    // This turn runs under the mode its *chat* was set to when Send was pressed
    // — switching the mode takes effect on the next message. Plan mode has two
    // shapes, exactly as it does for Hermes: the planning turn is forced
    // read-only (it must touch nothing), and the execute turn that follows an
    // approval carries the plan out asking per action, so `plan` maps to `ask`.
    final chosen = approval ?? _ref.read(chatPrefsProvider).approval;
    final mode = planFirst
        ? AgentApprovalMode.readOnly
        : (chosen == AgentApprovalMode.plan ? AgentApprovalMode.ask : chosen);

    final root = workdir ?? _ref.read(agentWorkspaceDirProvider).path;
    final turn = _slots.planTurn(
      key: '${network.networkId}|$model|$conversationId|$root',
      conversationId: conversationId,
      history: history,
      // Only a point this agent wrote, for the folder this turn runs in. A
      // Codex session id means nothing to `claude --resume`, and a session
      // resumed outside its own folder carries on editing files that aren't
      // the ones now open.
      adopt: _adoptable(resume, root),
    );
    final prompt = planFirst ? withPlanPreamble(turn.text) : turn.text;
    // A conversation starting over carries none of the last one's standing
    // yeses — the chat that gave them is gone.
    if (turn.freshStart) {
      _ref.read(agentSessionGrantsProvider.notifier).clear(chat);
    }

    // How much of the model Claude Code may fill before it summarizes — what
    // the grid advertises, what an engine taught, or the assumption the app
    // falls back on. See [modelContextWindowProvider].
    final window = _ref.read(modelContextWindowProvider(model));

    // Which browser this turn can reach, if any — decided per turn because the
    // answer moves between two messages: the user installs the extension,
    // restarts Chrome, or switches to a model the extension can't serve.
    final browser = await _openBrowser(model);
    final onExtension = browser.lane == ClaudeBrowserLane.extension;

    // Rewritten per turn, not cached: a connector signed in or disconnected
    // since the last message has to be in — or out of — this one. Null when the
    // write failed, which launches the turn on `~/.claude.json` rather than on
    // a path `claude` would reject. See [ClaudeTurnMcpConfig.write].
    final mcpConfigPath = await ClaudeTurnMcpConfig().write(
      extra: browser.mcpExtra,
    );

    // On the extension lane Claude Code runs against its own sign-in, where the
    // relay's name for the seat (`claude:opus`) is not a model it knows.
    final turnModel = onExtension ? claudeLocalModel(model) : model;
    final environment = onExtension
        ? const <String, String>{}
        : claudeCodeEnv(
            network.relayBaseUrl,
            network.relayApiKey,
            [model],
            compactWindow: agentContextCeiling(window),
            // A chat turn, so the ~922 KB reference for Anthropic's API — and
            // every other bundle that could grow to match it — stays out of a
            // window this turn needs for the conversation. Grid's own skills
            // live elsewhere and are untouched.
            withoutBundledSkills: true,
          );
    final dropEnvironment = onExtension
        ? kClaudeRelayEnvKeys
        : const <String>{};

    // Whether to take away Claude Code's server-side web tools for this turn.
    //
    // They are the provider's to run, so whatever answers the request has to
    // understand them. On the extension lane that is Anthropic itself; on a
    // `claude:*` seat it is Claude Code behind the relay — both keep them. A
    // grid model does not: the relay has no chat-completions equivalent to
    // translate them into and refuses the **whole request**, so asking for
    // today's weather spent a step on `400 Unsupported tool type:
    // web_search_20250305` before the agent fell back to the `grid-web` skill.
    // Denied up front, the fallback is simply the route.
    final withoutServerWebTools = !onExtension && !isClaudeSeatModel(model);

    // Make room *before* the turn, not after the refusal.
    //
    // The same ceiling already rides in [environment] for Claude Code's own
    // auto-compact to honour, and on a grid model it measurably doesn't — see
    // [needsCompaction]. So the app asks the question itself, from the figure
    // the last turn reported ([ClaudeContextUsed]), and asks for the summary
    // itself when the answer is yes.
    if (turn.resumeSessionId case final session?
        when needsCompaction(
          usedTokens: turn.slot.usedTokens,
          engineWindow: window,
        )) {
      await _compact(
        workdir: root,
        model: turnModel,
        environment: environment,
        sessionId: session,
        mcpConfigPath: mcpConfigPath,
        chrome: onExtension,
        withoutServerWebTools: withoutServerWebTools,
        dropEnvironment: dropEnvironment,
        chat: chat,
        slot: turn.slot,
      );
    }

    yield* _runTurn(
      workdir: root,
      prompt: withProjectInstructions(
        prompt,
        turn.freshStart ? instructions : null,
      ),
      // Off the slot, not off the plan, so what gets resumed is whatever the
      // compaction's own `init` line stated. The same id either way today (see
      // [_compact]) — reading it here is what keeps that a fact the CLI reports
      // rather than one this call assumes.
      resumeSessionId: turn.slot.sessionId ?? turn.resumeSessionId,
      model: turnModel,
      environment: environment,
      planFirst: planFirst,
      slot: turn.slot,
      chat: chat,
      mcpConfigPath: mcpConfigPath,
      chrome: onExtension,
      withoutServerWebTools: withoutServerWebTools,
      dropEnvironment: dropEnvironment,
      approval: mode,
    );
  }

  /// Ask Claude Code to summarize this session so the next turn has room.
  ///
  /// A separate `claude --resume <id>` run whose entire prompt is `/compact` —
  /// the CLI's own command, which keeps a summary of the work **in** the session
  /// rather than throwing the session away. The app already knows how to throw
  /// it away ([_contextFull] does exactly that, after the failure); this is the
  /// version that doesn't cost the agent everything it had worked out.
  ///
  /// It runs headless, so the command has to be one that works there:
  /// `/compact` declares `supportsNonInteractive: true` in its own definition
  /// inside the installed binary, verified rather than assumed — a command that
  /// didn't would be taken as a literal prompt and silently do nothing but burn
  /// a turn.
  ///
  /// **Best effort, on purpose.** Every failure path here returns without
  /// raising: a compaction that can't run must not swallow the user's message.
  /// The turn goes ahead on the un-summarized session and, if it really is too
  /// long, fails exactly the way it did before any of this existed.
  Future<void> _compact({
    required String workdir,
    required String model,
    required Map<String, String> environment,
    required String sessionId,
    required String? mcpConfigPath,
    required bool chrome,
    required bool withoutServerWebTools,
    required Set<String> dropEnvironment,
    required String chat,
    required AgentSessionSlot slot,
  }) async {
    final service = _ref.read(claudeExecServiceProvider);
    if (service == null) return;

    final runs = _ref.read(agentRunsProvider.notifier);
    final log = _ref.read(appLogProvider);
    // In the feed rather than in the log alone: summarizing is a whole model
    // round-trip, and a chat that sits silent for half a minute before the
    // answer starts reads as an app that has hung.
    const label = 'Making room — summarizing the conversation so far';
    runs.upsertStep(
      chat,
      const AgentActivity(
        id: _compactStepId,
        kind: AgentActivityKind.tool,
        label: label,
        status: AgentActivityStatus.running,
      ),
    );

    String? failure;
    try {
      final run = service.run(
        workdir: workdir,
        prompt: kClaudeCompactCommand,
        model: model,
        environment: environment,
        resumeSessionId: sessionId,
        mcpConfigPath: mcpConfigPath,
        chrome: chrome,
        withoutServerWebTools: withoutServerWebTools,
        dropEnvironment: dropEnvironment,
      );
      await for (final event in run.events) {
        switch (event) {
          // Whatever id the CLI opens with, recorded rather than assumed. It is
          // the same one in practice — `--resume` reuses the original, and a
          // new id needs `--fork-session`, which no turn here passes — so this
          // normally writes back what it already had. It exists because
          // [_runTurn] treats its own `init` line the same way: which session
          // is live is the CLI's to state, and a build that changed its mind
          // would otherwise leave the next turn resuming one that is gone.
          case ClaudeSessionStarted(:final sessionId):
            slot.sessionId = sessionId;
          case ClaudeTurnFailed(:final message):
            failure = message;
          // Summarizing calls no tools, so this should never fire — but an
          // unanswered request stops the turn dead, and this one has no user
          // watching it. A no here costs a summary; silence would cost the
          // whole conversation, waiting on a card nobody can see.
          case ClaudePermissionRequested(:final request):
            run.answerPermission(request.id, null);
          default:
        }
      }
      await run.done;
    } on ClaudeExecException catch (error) {
      failure = error.message;
    } on Object catch (error) {
      failure = '$error';
    }

    if (failure == null) {
      // Zero, not a guess at the summary's size: the next turn reports its own
      // figure, and leaving the old one standing would compact again on the
      // turn after this — every turn, forever.
      slot.usedTokens = 0;
      log.info('agent', 'summarized the session before the next turn');
    } else {
      log.failure('agent', "couldn't summarize the session: $failure");
    }
    runs.upsertStep(
      chat,
      AgentActivity(
        id: _compactStepId,
        kind: AgentActivityKind.tool,
        label: label,
        status: failure == null
            ? AgentActivityStatus.done
            : AgentActivityStatus.failed,
      ),
    );
  }

  /// Say so when a turn that asked for the browser didn't get it.
  ///
  /// The extension is an MCP server like any other, and the tool list closes on
  /// whatever answered by then: a turn can carry `--chrome`, report the lane in
  /// the log, and still hold no browser tools at all — measured here at 27 tools
  /// against 49 once the server connected. Without this line the only symptom is
  /// an agent that talks about the browser and never opens it.
  void _checkBrowserServer(Map<String, String> statuses) {
    final status = statuses[kClaudeInChromeServer];
    if (status == 'connected') return;
    _ref
        .read(appLogProvider)
        .failure(
          'agent',
          'Browser lane extension: the turn started with --chrome but '
              '$kClaudeInChromeServer is ${status ?? 'absent'} — this turn has '
              'no browser tools',
        );
  }

  /// The browser lane this turn takes, with the fallback browser already started
  /// if that is the lane — so the caller gets a lane it can act on rather than a
  /// promise that may not hold.
  ///
  /// Every outcome is logged, including the ones that take no browser at all:
  /// "the agent didn't use my browser" is the report this feature generates, and
  /// the log is the only place that can answer it (§6).
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

  /// Run one turn: stream the answer into the bubble as it arrives, mirror tool
  /// steps into the activity feed, and end with the finished reply.
  ///
  /// Driven by an explicit subscription (not `await for`) so Stop tears the turn
  /// down there and then — cancelling the stream kills the `claude` process.
  Stream<ChatSendUpdate> _runTurn({
    required String workdir,
    required String prompt,
    required String? resumeSessionId,
    required String model,
    required Map<String, String> environment,
    required bool planFirst,
    required AgentSessionSlot slot,
    required String chat,
    required String? mcpConfigPath,
    required bool chrome,
    required bool withoutServerWebTools,
    required Set<String> dropEnvironment,
    required AgentApprovalMode approval,
  }) {
    final runs = _ref.read(agentRunsProvider.notifier);
    final log = _ref.read(commandLogProvider.notifier);
    // The argv comes from the same pure builder the service runs, so the Debug
    // tab shows the flags this turn really carried and not a second copy of them.
    final logId = log.begin(
      CliCallKind.start,
      'claude -p $model (agent)',
      detail: agentTurnDetail(
        args: [
          'claude',
          ...claudeExecArgs(
            model: model,
            resumeSessionId: resumeSessionId,
            mcpConfigPath: mcpConfigPath,
            chrome: chrome,
            withoutServerWebTools: withoutServerWebTools,
          ),
        ],
        workdir: workdir,
        environment: environment,
        prompt: prompt,
      ),
    );

    final run = _ref
        .read(claudeExecServiceProvider)!
        .run(
          workdir: workdir,
          prompt: prompt,
          model: model,
          environment: environment,
          resumeSessionId: resumeSessionId,
          mcpConfigPath: mcpConfigPath,
          withoutServerWebTools: withoutServerWebTools,
          chrome: chrome,
          dropEnvironment: dropEnvironment,
        );

    final answer = StringBuffer();
    // The answer up to its last finished block — where the turn may be divided.
    // See [ClaudeMessageEvent.settled].
    var settledText = '';
    final updates = StreamController<ChatSendUpdate>();
    // What each file Claude is about to write held beforehand, so a landed write
    // can be shown as a real before/after and undone. Captured from the tool
    // *call*, which is the last moment the old contents still exist.
    final before = <String, String?>{};
    String? failure;
    var settled = false;
    // The two facts the stall check reads — see [agentTurnStalled].
    var endedCleanly = false;
    var workedAtAll = false;

    final events = run.events.listen(
      (event) {
        switch (event) {
          case ClaudeSessionStarted(:final sessionId):
            slot.sessionId = sessionId;
          case ClaudeServersAnnounced(:final statuses):
            if (chrome) _checkBrowserServer(statuses);
          case ClaudeActivityEvent(:final activity):
            if (isAgentWork(activity)) workedAtAll = true;
            // With what has been said so far, so the step lands *after* that
            // passage in the turn's timeline rather than under the whole answer.
            //
            // The *settled* text, not the streaming one: a step — a sub-agent's,
            // usually — can arrive between two deltas of a sentence Claude is
            // still typing, and dividing the turn there would split that
            // sentence around it.
            runs.upsertStep(chat, activity, answer: settledText);
          case ClaudePlanEvent(:final entries):
            runs.setPlan(chat, entries);
          case ClaudeFileWriteStarted(:final path):
            workedAtAll = true;
            before[path] = readTextFileNow(path);
          case ClaudeFileWriteFinished(:final path):
            _recordChange(chat, path, before.remove(path));
          case ClaudePermissionRequested(:final request):
            decideAgentPermission(
              ref: _ref,
              agent: 'claude',
              chat: chat,
              request: request,
              approval: approval,
              grantKey: claudePermissionGrantKey(request),
              answer: (optionId) => run.answerPermission(request.id, optionId),
            );
          case ClaudeGoalNotMet(:final condition, :final reason):
            updates.add(
              ChatSendGoalProgress(condition: condition, reason: reason),
            );
          case ClaudeTurnCompleted():
            endedCleanly = true;
          // Kept per request, not per turn: an agentic turn calls the model
          // many times and the last call is where the session actually stands.
          case ClaudeContextUsed(:final tokens):
            slot.usedTokens = tokens;
          case ClaudeMessageEvent(:final text, settled: final blocks):
            answer
              ..clear()
              ..write(text);
            settledText = blocks;
            updates.add(ChatSendStreaming(text));
          case ClaudeTurnFailed(:final message):
            failure = friendlyClaudeError(message);
            _logRaw(message);
            if (isContextOverflow(message)) _contextFull(model, message, slot);
        }
      },
      onError: (Object error) {
        failure = error is ClaudeExecException
            ? (error.retryable
                  ? "Couldn't start Claude Code on this computer. Try sending "
                        'again.'
                  : "Couldn't start Claude Code on this computer. "
                        '${error.message}')
            : friendlyClaudeError('$error');
        _logRaw('$error');
      },
      onDone: () async {
        await run.done;
        settled = true;
        // The turn is over: a card left pinned would be a button that answers
        // nobody.
        _ref.read(agentPermissionsProvider.notifier).clear(chat);
        final reply = answer.toString().trim();
        final plan = _ref.read(agentRunProvider(chat)).plan;
        // A turn that announced a plan and stopped before finishing it is worth
        // recording — but only recording, and identically for every agent: the
        // verdict is a guess about work the app can't see, and calling a finished
        // answer a failure on the strength of an unticked box put an error over
        // turns that had answered (§5).
        if (agentTurnStalled(
          plan: plan,
          endedCleanly: endedCleanly,
          workedAtAll: workedAtAll,
          planFirst: planFirst,
        )) {
          _ref
              .read(appLogProvider)
              .failure(
                'agent',
                describeAgentStall(
                  plan: plan,
                  endedCleanly: endedCleanly,
                  workedAtAll: workedAtAll,
                ),
              );
        }
        final error = failure ?? (reply.isEmpty ? kAgentNoAnswer : null);
        log.finish(logId, error: error);
        // The answer is about to be appended to the chat, and Claude wrote it —
        // so its session already holds it. Counting it here keeps the next turn
        // from quoting Claude's own words back at it as "context you missed".
        // Only on success: a failed turn appends nothing.
        if (error == null) slot.seen++;
        updates.add(
          error != null
              ? ChatSendFailure(error)
              : ChatSendSuccess(
                  ChatMessage(
                    role: ChatRole.assistant,
                    text: reply,
                    plan: plan,
                  ),
                ),
        );
        await updates.close();
      },
    );

    // The user hit Stop (or left the chat). A clean finish also lands here via
    // the done above (with [settled] set) and must not re-kill anything.
    updates.onCancel = () async {
      await events.cancel();
      _ref.read(agentPermissionsProvider.notifier).clear(chat);
      if (settled) return;
      run.kill();
      log.finish(logId, error: 'stopped');
    };
    return updates.stream;
  }

  /// Record a landed write so the chat can offer to open — and undo — what the
  /// agent just changed (see `AgentChangesBar`). Unlike Codex, whose events drop
  /// the previous contents, Claude's are seen early enough to keep them, so an
  /// *edit* gets a true diff here and not just an Open button.
  void _recordChange(String chat, String path, String? previous) {
    final changesLog = _ref.read(agentChangesProvider.notifier);
    unawaited(() async {
      String after;
      try {
        after = await File(path).readAsString();
      } on Object {
        // Gone or unreadable: still worth an Open, so record it with no diff
        // rather than dropping it.
        after = '';
      }
      changesLog.record(
        chatId: chat,
        path: path,
        before: previous,
        after: after,
      );
    }());
  }

  /// The model ran out of room. Two things follow, and both are for the *next*
  /// turn — this one is already lost.
  ///
  /// The window the engine named is remembered, so every later turn on this
  /// model starts with a ceiling and summarizes instead of walking into the same
  /// wall (see [modelContextWindowProvider]). And the session is dropped:
  /// resuming it would hand the engine the identical over-long conversation and
  /// fail identically, which is the loop the user was stuck in — a fresh session
  /// replays only the recent messages, which is what [kClaudeContextFull]
  /// promises.
  void _contextFull(String model, String raw, AgentSessionSlot slot) {
    slot.sessionId = null;
    final window = contextWindowFromError(raw);
    if (window == null) return;
    _ref.read(learnedModelContextProvider.notifier).learn(model, window);
    _ref
        .read(appLogProvider)
        .info(
          'agent',
          '$model holds $window tokens; later turns compact at '
              '${agentContextCeiling(window)}',
        );
  }

  /// Keep Claude's own words for the log while the chat shows the friendly line.
  ///
  /// Without this the raw reason is lost the moment it's humanized, and the log
  /// only repeats the sentence the user already read — leaving no way to tell a
  /// relay that answers no `/messages` from a rejected token or a dead network.
  void _logRaw(String raw) =>
      _ref.read(appLogProvider).failure('agent', 'claude turn failed: $raw');
}

/// Shown when the grid had nothing to answer Claude's request with.
///
/// The grid-wide case is already headed off before the send (a grid that serves
/// nothing Claude can talk to never gets handed the chat — see
/// `agentRunsOnGrid`), so what's left is the model: this grid *can* answer
/// Claude somewhere, just not with the one the user picked. Say that, and
/// nothing about whether another agent would do better — the chat pairs this
/// with a button that switches, which is an offer to try, not a promise.
const String kClaudeDialectFailure =
    "This model can't answer the kind of request Claude Code sends. Pick a "
    'model it supports, or let another agent take this chat.';

/// Shown when the grid took Claude's request and had nobody to give it to.
///
/// A different failure from [kClaudeDialectFailure] and a different fix: the
/// endpoint is there, so the request was understood — there is simply no machine
/// online serving this model that way.
const String kClaudeNoProviderFailure =
    'No machine on this grid is serving a model Claude Code can use right now. '
    'Try another model, or let another agent take this chat.';

/// Shown when the conversation outgrew the model serving it.
///
/// Says what to do rather than what broke: the app has already dropped the
/// session behind the scenes ([ClaudeChatSender._contextFull]), so sending again
/// really does carry on — from the recent messages, which is the honest promise.
/// It doesn't offer "a model with more room": no grid says how much room any of
/// its models has (`TODO(BE)`), so that would be a guess dressed as advice.
const String kClaudeContextFull =
    'This chat got longer than the model can hold. Send again and the assistant '
    'picks it up from the recent messages — everything said stays here.';

/// Humanize Claude's failure so the chat shows a next step, not a stack trace.
///
/// Claude reports HTTP trouble as `API Error: <status> <body>`; a raw
/// `API Error: 404 {"detail":"Not Found"}` is a log line, not something anyone
/// can act on. Everything else keeps Claude's own last line, which at least says
/// what it was doing.
String friendlyClaudeError(String raw) {
  // An empty/unparseable model response reads the same whichever agent hit it,
  // so both route through the one shared line.
  final empty = friendlyAgentEmptyResponse(raw);
  if (empty != null) return empty;
  // Ahead of the status-code branches below: this one arrives as a 400, and
  // "bad request" is the least useful thing that could be said about it.
  if (isContextOverflow(raw)) return kClaudeContextFull;

  final detail = raw
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .lastOrNull;
  if (detail == null || detail.isEmpty) {
    return "Claude Code couldn't finish. Check your connection and try again.";
  }
  final lower = detail.toLowerCase();
  if (lower.contains('no providers') || lower.contains('503')) {
    return kClaudeNoProviderFailure;
  }
  if (lower.contains('404') || lower.contains('not found')) {
    return kClaudeDialectFailure;
  }
  return "Claude Code couldn't finish: $detail";
}
