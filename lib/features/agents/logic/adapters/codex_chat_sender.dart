import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/cli/agent_event.dart';
import '../../../../infrastructure/cli/agent_resume_point.dart';
import '../../../../infrastructure/cli/codex_agent_service.dart';
import '../../../../infrastructure/cli/codex_app_server_service.dart';
import '../../../../infrastructure/cli/command_log.dart';
import '../../../../infrastructure/logging/app_log.dart';
import '../../../../infrastructure/state/chat_prefs_store.dart';
import '../../../../infrastructure/state/models/network_credential.dart';
import '../../../../shared/copy/setup_hints.dart';
import '../../../network/logic/app_guide_snippets.dart';
import '../../../playground/logic/chat_message.dart';
import '../../../playground/logic/chat_sender.dart';
import '../../../playground/logic/playground_request.dart';
import '../agent_catalog.dart';
import '../agent_changes.dart';
import '../agent_prompt.dart';
import '../agent_session_slots.dart';
import '../agent_steering.dart';
import '../agent_turn_log.dart';
import '../agent_server_error.dart';
import '../agent_permission_decision.dart';
import '../agent_permissions.dart';
import '../agent_providers.dart';
import 'codex_tool.dart';

/// The Codex seam, or null when Codex is absent.
final codexServiceProvider = Provider<CodexService?>((ref) {
  final path = ref.watch(codexPathProvider);
  return path == null ? null : CodexAppServerService(path);
});

/// A [ChatSender] backed by Codex over `codex app-server`.
///
/// Codex runs one turn per process and exits, so — unlike Hermes's persistent
/// ACP session — continuity comes from **resuming the thread**: the first turn
/// replays the history and learns Codex's `thread_id`, and each later turn sends
/// only the new message on a resumed thread, letting Codex hold the
/// conversation context itself. Switching conversation, grid or model starts a
/// fresh thread.
///
/// Codex streams the same activity/plan shapes Hermes does, so this feeds that
/// conversation's live run ([agentRunsProvider]) and streams the answer into the
/// bubble as it lands.
///
/// The grid it answers with is handed over **per run** — `-c` overrides on the
/// command line, the key in the child process's environment
/// ([codexGridOverrides]) — and nothing of the user's is written. This used to
/// rewrite `~/.codex/config.toml`, which is their file and their terminal
/// `codex`'s: chatting here changed the default model and provider for every
/// Codex session on the machine. Their config is still *read*, so the MCP
/// servers in it stay available to an in-app turn.
///
/// **How much it may touch is the chat's own setting** — the approval picker in
/// the composer reaches Codex now, through the thread's sandbox and approval
/// policy ([codexApprovalPolicy]), and a command it can't run unattended stops
/// and asks in the chat. Until 2026-08-18 there was no channel to ask on and
/// every turn ran with full access to this machine whatever the picker said.
///
/// Codex still judges the trivial cases itself — a bare `echo` is run without
/// anyone being asked — exactly as Hermes does, so copy must never promise that
/// *every* command is shown first.
final codexChatSenderProvider = Provider<ChatSender>((ref) {
  return CodexChatSender(ref);
});

class CodexChatSender implements ChatSender {
  CodexChatSender(this._ref);

  final Ref _ref;

  final _slots = AgentSessionSlots();

  /// [resume] when it is a Codex thread opened in [root], else null — the same
  /// two-part check the Claude sender makes, and for the same reason: an id
  /// from the other agent is meaningless here, and the right id in the wrong
  /// folder is worse than no id at all.
  static AgentResumePoint? _adoptable(AgentResumePoint? resume, String root) {
    if (resume == null) return null;
    return resume.matches(thisAgent: AgentTool.codex.id, thisWorkdir: root)
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
    if (_ref.read(codexServiceProvider) == null) {
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

    // This turn runs under the mode its *chat* was set to when Send was pressed.
    // Plan mode has two shapes, as it does for every agent: the planning turn is
    // forced read-only, and the execute turn that follows carries the plan out
    // asking per action.
    final chosen = approval ?? _ref.read(chatPrefsProvider).approval;
    final mode = planFirst
        ? AgentApprovalMode.readOnly
        : (chosen == AgentApprovalMode.plan ? AgentApprovalMode.ask : chosen);

    final root = workdir ?? _ref.read(agentWorkspaceDirProvider).path;
    final turn = _slots.planTurn(
      key: '${network.networkId}|$model|$conversationId|$root',
      conversationId: conversationId,
      history: history,
      adopt: _adoptable(resume, root),
    );
    final prompt = planFirst ? withPlanPreamble(turn.text) : turn.text;

    yield* _runTurn(
      workdir: root,
      prompt: withProjectInstructions(
        prompt,
        turn.freshStart ? instructions : null,
      ),
      resumeThreadId: turn.resumeSessionId,
      model: model,
      // The grid rides on this run's own command line, and its key in this
      // process's environment — nothing on disk is touched, so the user's
      // terminal `codex` keeps answering with whatever *they* pointed it at.
      config: codexGridOverrides(base: network.relayBaseUrl, model: model),
      approval: mode,
      environment: {kCodexAppApiKeyEnv: network.relayApiKey},
      planFirst: planFirst,
      slot: turn.slot,
      chat: chat,
    );
  }

  /// Run one turn: stream the answer into the bubble as it arrives, mirror tool
  /// steps into the activity feed, and end with the finished reply.
  ///
  /// Driven by an explicit subscription (not `await for`) so Stop tears the turn
  /// down there and then — cancelling the stream kills the server process.
  Stream<ChatSendUpdate> _runTurn({
    required String workdir,
    required String prompt,
    required String? resumeThreadId,
    required String model,
    required List<String> config,
    required Map<String, String> environment,
    required bool planFirst,
    required AgentSessionSlot slot,
    required String chat,
    required AgentApprovalMode approval,
  }) {
    // The feed was reset up front in [send], before the grid setup — see
    // [AgentRuns.reset]; here we only take the notifier to append to. That reset
    // also drops any prior Hermes turn's citations, so they can't linger under a
    // Codex answer (Codex cites no sources of its own today).
    final runs = _ref.read(agentRunsProvider.notifier);
    final log = _ref.read(commandLogProvider.notifier);
    // Same builder the service runs (see [codexAppServerArgs]) — the `-c`
    // overrides are where a turn's grid and model actually live, and a wrong one
    // fails exactly like a model that wouldn't answer, so they belong on screen.
    final logId = log.begin(
      CliCallKind.start,
      'codex app-server -m $model (agent)',
      detail: agentTurnDetail(
        args: [
          'codex',
          ...codexAppServerArgs(config: config),
        ],
        workdir: workdir,
        environment: environment,
        prompt: prompt,
      ),
    );

    final service = _ref.read(codexServiceProvider)!;
    final run = service.run(
      workdir: workdir,
      prompt: prompt,
      config: config,
      environment: environment,
      approval: approval,
      resumeThreadId: resumeThreadId,
    );

    // Anything typed in this chat while the turn runs goes into the turn itself
    // (`turn/steer`), not into a queue behind it, and is recorded in the turn's
    // timeline where it happened (see [AgentSteeringController]).
    final steering = _ref.read(agentSteeringProvider.notifier);
    steering.offer(chat, run.steer);

    final answer = StringBuffer();
    final updates = StreamController<ChatSendUpdate>();
    String? failure;
    var settled = false;
    // The two facts the stall check reads — see [agentTurnStalled]: whether
    // Codex ended the turn itself, and whether it did any work at all. Neither
    // is reset by a plan revision: Codex ticks its boxes on the way out.
    var endedCleanly = false;
    var workedAtAll = false;

    final events = run.events.listen(
      (event) {
        switch (event) {
          case CodexThreadStarted(:final threadId):
            slot.sessionId = threadId;
          case CodexActivityEvent(:final activity):
            if (isAgentWork(activity)) workedAtAll = true;
            // With what has been said so far, so the step lands *after* that
            // passage in the turn's timeline rather than under the whole answer.
            runs.upsertStep(chat, activity, answer: answer.toString());
          case CodexPlanEvent(:final entries):
            runs.setPlan(chat, entries);
          case CodexFileChangeEvent(:final changes):
            workedAtAll = true;
            _recordAddedFiles(chat, changes);
          case CodexPermissionRequested(:final request):
            decideAgentPermission(
              ref: _ref,
              agent: 'codex',
              chat: chat,
              request: request,
              approval: approval,
              // No key: Codex holds its own "for the rest of this thread" yes,
              // so a second memory here would only be able to disagree with it.
              answer: (optionId) => run.answerPermission(request.id, optionId),
            );
          case CodexTurnCompleted():
            endedCleanly = true;
          case CodexMessageEvent(:final text):
            answer
              ..clear()
              ..write(text);
            updates.add(ChatSendStreaming(text));
          case CodexTurnFailed(:final message):
            failure = friendlyCodexError(message);
            _logRaw(message);
        }
      },
      onError: (Object error) {
        failure = error is CodexException
            ? (error.retryable
                  ? "Couldn't start Codex on this computer. Try sending again."
                  : "Couldn't start Codex on this computer. ${error.message}")
            : friendlyCodexError('$error');
        _logRaw('$error');
      },
      onDone: () async {
        await run.done;
        settled = true;
        // The turn is over: a card left pinned would answer nobody, and a
        // message typed from here belongs to the next turn.
        _ref.read(agentPermissionsProvider.notifier).clear(chat);
        steering.withdraw(chat);
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
        // The answer is about to be appended to the chat, and Codex wrote it —
        // so its thread already holds it. Counting it here keeps the next turn
        // from quoting Codex's own words back at it as "context you missed".
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
      steering.withdraw(chat);
      if (settled) return;
      run.kill();
      log.finish(logId, error: 'stopped');
    };
    return updates.stream;
  }

  /// Record every file Codex freshly created so the chat can offer to open it —
  /// the point of a "make me a page or a game" turn, which otherwise leaves the
  /// user a bare file path in the reply and no way to act on it (see
  /// `AgentChangesBar`). Only adds are recorded: Codex reports an edit's path but
  /// not its old contents, so an update has no honest before to diff or undo.
  void _recordAddedFiles(String chat, List<CodexFileChange> changes) {
    final changesLog = _ref.read(agentChangesProvider.notifier);
    for (final path in codexAddedPaths(changes)) {
      unawaited(_recordAddedFile(chat, path, changesLog));
    }
  }

  /// Read the just-written file so its "before → after" diff shows the whole new
  /// file, and record it with a null [AgentChange.before] so undo deletes it. A
  /// path that can't be read (binary, or already gone) is still worth an Open, so
  /// it's recorded with no diff rather than dropped.
  Future<void> _recordAddedFile(
    String chat,
    String path,
    AgentChangesController changesLog,
  ) async {
    String after;
    try {
      after = await File(path).readAsString();
    } on Object {
      after = '';
    }
    changesLog.record(chatId: chat, path: path, before: null, after: after);
  }

  /// Keep Codex's own words for the log while the chat shows the friendly line.
  ///
  /// Without this the raw reason is lost the moment it's humanized, and the log
  /// only repeats the sentence the user already read — leaving no way to tell a
  /// relay that answers no `/responses` from a rejected key or a dead network.
  void _logRaw(String raw) =>
      _ref.read(appLogProvider).failure('agent', 'codex turn failed: $raw');
}

/// Shown when the grid answered Codex's request with a flat "no such endpoint".
///
/// The grid-wide case is already headed off before the send (a grid that serves
/// nothing Codex can talk to never gets handed the chat — see
/// `agentRunsOnGrid`), so what's left is the model: this grid *can* answer Codex
/// somewhere, just not with the one the user picked. Say that, and nothing about
/// whether another agent would do better — the chat pairs this with a button
/// that switches, which is an offer to try, not a promise.
///
/// Neither sentence names another agent: the chat pairs both with a button that
/// hands the turn over, which is an offer to try, not a promise that it works.
const String kCodexDialectFailure =
    "This model can't answer the kind of request Codex sends. Pick a model "
    'Codex supports, or let another agent take this chat.';

/// Shown when the grid took Codex's request and had nobody to give it to.
///
/// A different failure from [kCodexDialectFailure] and a different fix: the
/// endpoint is there, so the request was understood — there is simply no machine
/// online serving this model that way. Reading the two as one ("wrong model")
/// would send the user renaming models while the real answer is that the grid is
/// empty right now.
const String kCodexNoProviderFailure =
    'No machine on this grid is serving a model Codex can use right now. Try '
    'another model, or let another agent take this chat.';

/// Humanize Codex's failure so the chat shows a next step, not a stack trace.
///
/// The failures a user actually hits are the two Responses ones above — a raw
/// `unexpected status 503 Service Unavailable: {"detail":…}, url: …/v1/responses`
/// is a log line, not something anyone can act on. Everything else keeps Codex's
/// own last line, which at least says what it was doing.
String friendlyCodexError(String raw) {
  // An empty/unparseable model response reads the same whichever agent hit it,
  // so both route through the one shared line (see [friendlyAgentEmptyResponse]).
  final empty = friendlyAgentEmptyResponse(raw);
  if (empty != null) return empty;

  final lines = raw
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty);
  // Codex's own `error:` line when there is one, else its last. A rejected
  // command prints the reason first and usage after it, so taking the last line
  // showed the user "For more information, try '--help'." and nothing else.
  final detail =
      lines.where((line) => line.startsWith('error:')).firstOrNull ??
      lines.lastOrNull;
  if (detail == null || detail.isEmpty) {
    return "Codex couldn't finish. Check your connection and try again.";
  }
  final lower = detail.toLowerCase();
  // Only a failure of the Responses call itself gets rewritten — Codex reports
  // the endpoint in the same line, so anything else is a failure we'd be
  // guessing about.
  if (!lower.contains('responses')) return "Codex couldn't finish: $detail";
  if (lower.contains('no providers') || lower.contains('503')) {
    return kCodexNoProviderFailure;
  }
  if (lower.contains('404') ||
      lower.contains('not found') ||
      lower.contains('disconnected')) {
    return kCodexDialectFailure;
  }
  return "Codex couldn't finish: $detail";
}
