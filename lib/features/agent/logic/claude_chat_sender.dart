import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/cli/claude_exec_event.dart';
import '../../../infrastructure/cli/claude_exec_service.dart';
import '../../../infrastructure/cli/command_log.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../network/logic/app_guide_snippets.dart';
import '../../playground/logic/chat_message.dart';
import '../../playground/logic/chat_sender.dart';
import '../../playground/logic/playground_request.dart';
import 'agent_changes.dart';
import 'agent_prompt.dart';
import 'agent_providers.dart';
import 'agent_server_error.dart';
import 'agent_session_slots.dart';
import 'claude_tool.dart';

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
  }) async* {
    if (modality != PlaygroundModality.text) {
      yield const ChatSendFailure('The agent can only answer in text.');
      return;
    }
    if (_ref.read(claudeExecServiceProvider) == null) {
      yield const ChatSendFailure(
        "This computer isn't set up to answer chats yet. Open the account menu "
        '▸ This computer to finish setting it up.',
      );
      return;
    }
    if (history.isEmpty || history.last.text.trim().isEmpty) {
      yield const ChatSendFailure('Nothing to send.');
      return;
    }

    // Clear the shared feed now, so the chat's "working" bubble, already on
    // screen, can't flash the previous turn's steps (or another chat's). See
    // [resetAgentFeed].
    resetAgentFeed(_ref);

    final root = workdir ?? _ref.read(agentWorkspaceDirProvider).path;
    final turn = _slots.planTurn(
      key: '${network.networkId}|$model|$conversationId|$root',
      conversationId: conversationId,
      history: history,
    );
    final prompt = planFirst ? withPlanPreamble(turn.text) : turn.text;

    yield* _runTurn(
      workdir: root,
      prompt: withProjectInstructions(
        prompt,
        turn.freshStart ? instructions : null,
      ),
      resumeSessionId: turn.resumeSessionId,
      model: model,
      environment: claudeCodeEnv(network.relayBaseUrl, network.relayApiKey, [
        model,
      ]),
      planFirst: planFirst,
      slot: turn.slot,
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
  }) {
    final activityLog = _ref.read(agentActivityProvider.notifier);
    final planLog = _ref.read(agentPlanProvider.notifier);
    final log = _ref.read(commandLogProvider.notifier);
    final logId = log.begin(CliCallKind.start, 'claude -p $model (agent)');

    final run = _ref
        .read(claudeExecServiceProvider)!
        .run(
          workdir: workdir,
          prompt: prompt,
          model: model,
          environment: environment,
          resumeSessionId: resumeSessionId,
        );

    final answer = StringBuffer();
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
          case ClaudeActivityEvent(:final activity):
            if (isAgentWork(activity)) workedAtAll = true;
            activityLog.upsert(activity);
          case ClaudePlanEvent(:final entries):
            planLog.replace(entries);
          case ClaudeFileWriteStarted(:final path):
            workedAtAll = true;
            before[path] = _readNow(path);
          case ClaudeFileWriteFinished(:final path):
            _recordChange(path, before.remove(path));
          case ClaudeTurnCompleted():
            endedCleanly = true;
          case ClaudeMessageEvent(:final text):
            answer
              ..clear()
              ..write(text);
            updates.add(ChatSendStreaming(text));
          case ClaudeTurnFailed(:final message):
            failure = friendlyClaudeError(message);
            _logRaw(message);
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
        final reply = answer.toString().trim();
        final plan = _ref.read(agentPlanProvider);
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
      if (settled) return;
      run.kill();
      log.finish(logId, error: 'stopped');
    };
    return updates.stream;
  }

  /// What [path] holds right now, or null when it isn't there — which is what
  /// tells a fresh file from an overwrite, and so an undo that deletes from one
  /// that restores.
  ///
  /// Synchronous on purpose: it runs while the tool call is being announced, and
  /// an `await` here would let the write land first and read back its own result
  /// as the "before".
  static String? _readNow(String path) {
    try {
      final file = File(path);
      return file.existsSync() ? file.readAsStringSync() : null;
    } on FileSystemException {
      // Unreadable (binary, permissions): no honest "before" rather than a
      // claim that the file was empty.
      return null;
    }
  }

  /// Record a landed write so the chat can offer to open — and undo — what the
  /// agent just changed (see `AgentChangesBar`). Unlike Codex, whose events drop
  /// the previous contents, Claude's are seen early enough to keep them, so an
  /// *edit* gets a true diff here and not just an Open button.
  void _recordChange(String path, String? previous) {
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
      changesLog.record(path: path, before: previous, after: after);
    }());
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
