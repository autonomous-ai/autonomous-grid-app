import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/cli/codex_exec_service.dart';
import '../../../infrastructure/cli/command_log.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../network/logic/client_app_configurator.dart';
import '../../network/logic/client_app_detector.dart';
import '../../playground/logic/chat_message.dart';
import '../../playground/logic/chat_sender.dart';
import '../../playground/logic/playground_request.dart';
import '../../agents/logic/agent_catalog.dart';
import 'agent_changes.dart';
import 'agent_prompt.dart';
import 'agent_server_error.dart';
import 'agent_providers.dart';
import 'agent_skill_installer.dart';
import 'codex_tool.dart';

/// The Codex exec seam, or null when Codex is absent.
final codexExecServiceProvider = Provider<CodexExecService?>((ref) {
  final path = ref.watch(codexPathProvider);
  return path == null ? null : CodexExecServiceImpl(path);
});

/// The `networkId|model` Codex's config was last pointed at, so `~/.codex` is
/// only rewritten when the target grid or model changes. Codex reads the model
/// and endpoint from its config, so the config must carry the current selection.
final codexConfiguredProvider = NotifierProvider<CodexConfigured, String?>(
  CodexConfigured.new,
);

class CodexConfigured extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? key) => state = key;
}

/// A [ChatSender] backed by Codex over `codex exec --json`.
///
/// Codex runs one turn per process and exits, so — unlike Hermes's persistent
/// ACP session — continuity comes from **resuming the thread**: the first turn
/// replays the history and learns Codex's `thread_id`, and each later turn sends
/// only the new message with `codex exec resume <id>`, letting Codex hold the
/// conversation context itself. Switching conversation, grid or model starts a
/// fresh thread.
///
/// Codex streams the same activity/plan shapes Hermes does, so this feeds the
/// shared activity feed ([agentActivityProvider]) and streams the answer into the
/// bubble as it lands.
///
/// It runs with **no sandbox** ([kCodexSandboxMode]): Codex changes files and
/// runs commands on this computer, and — unlike Hermes over ACP — `codex exec`
/// has no channel to ask first, so nothing here prompts the user. The approval
/// picker in the composer governs Hermes only; it has nothing to hand Codex.
/// TODO(BE): a per-action approval path for Codex would close that gap.
final codexChatSenderProvider = Provider<ChatSender>((ref) {
  return CodexChatSender(ref);
});

/// What the sender remembers between turns of one conversation, so it can resume
/// Codex's thread instead of starting over.
class _LiveThread {
  _LiveThread({required this.key, required this.seen});

  /// `networkId|model|conversationId|workdir` — a change in any of these means a
  /// new thread (a different grid, model, conversation or project folder).
  final String key;

  /// Codex's own id for the thread, known once the first turn reports it. Null
  /// until then, which forces the next turn to start fresh.
  String? threadId;

  /// The history length at the last prompt. A longer history next time is a
  /// continuation of the same chat; anything else restarts.
  int seen;
}

class CodexChatSender implements ChatSender {
  CodexChatSender(this._ref);

  final Ref _ref;
  _LiveThread? _live;

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
    if (_ref.read(codexExecServiceProvider) == null) {
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

    // Clear the shared feed now — synchronously, before the awaited grid setup
    // and skill install below — so the chat's "working" bubble, already on
    // screen, can't flash the previous turn's steps (or another chat's) while
    // Codex is pointed at the grid. See [resetAgentFeed].
    resetAgentFeed(_ref);

    final pointed = await _pointAtGrid(network, model);
    if (pointed != null) {
      yield ChatSendFailure(pointed);
      return;
    }

    final root = workdir ?? _ref.read(agentWorkspaceDirProvider).path;
    final resolved = _resolveTurn(
      network,
      model,
      conversationId,
      history,
      root,
    );
    final prompt = planFirst ? withPlanPreamble(resolved.text) : resolved.text;

    yield* _runTurn(
      workdir: root,
      prompt: withProjectInstructions(
        prompt,
        resolved.freshStart ? instructions : null,
      ),
      resumeThreadId: resolved.resumeThreadId,
      model: model,
      planFirst: planFirst,
    );
  }

  /// Decide between resuming this conversation's thread (send only the new turn)
  /// and starting fresh (replay the history). Returns the text to send, the
  /// thread to resume (null when starting fresh) and whether it's a fresh start.
  ({String text, String? resumeThreadId, bool freshStart}) _resolveTurn(
    NetworkCredential network,
    String model,
    String? conversationId,
    List<ChatMessage> history,
    String root,
  ) {
    final key = '${network.networkId}|$model|$conversationId|$root';
    final live = _live;
    final continues =
        live != null &&
        live.key == key &&
        live.threadId != null &&
        history.length > live.seen;

    if (continues) {
      live.seen = history.length;
      return (
        text: history.last.text.trim(),
        resumeThreadId: live.threadId,
        freshStart: false,
      );
    }

    _live = _LiveThread(key: key, seen: history.length);
    return (
      text: buildAgentPrompt(history),
      resumeThreadId: null,
      freshStart: true,
    );
  }

  /// Run one turn: stream the answer into the bubble as it arrives, mirror tool
  /// steps into the activity feed, and end with the finished reply.
  ///
  /// Driven by an explicit subscription (not `await for`) so Stop tears the turn
  /// down there and then — cancelling the stream kills the `codex exec` process.
  Stream<ChatSendUpdate> _runTurn({
    required String workdir,
    required String prompt,
    required String? resumeThreadId,
    required String model,
    required bool planFirst,
  }) {
    // The feed was reset up front in [send], before the grid setup — see
    // [resetAgentFeed]; here we only take the notifiers to append to. That reset
    // also drops any prior Hermes turn's citations, so they can't linger under a
    // Codex answer (Codex cites no sources of its own today).
    final activityLog = _ref.read(agentActivityProvider.notifier);
    final planLog = _ref.read(agentPlanProvider.notifier);
    final log = _ref.read(commandLogProvider.notifier);
    final logId = log.begin(CliCallKind.start, 'codex exec -m $model (agent)');

    final service = _ref.read(codexExecServiceProvider)!;
    final run = service.run(
      workdir: workdir,
      prompt: prompt,
      resumeThreadId: resumeThreadId,
    );

    final answer = StringBuffer();
    final updates = StreamController<ChatSendUpdate>();
    String? failure;
    var settled = false;

    final events = run.events.listen(
      (event) {
        switch (event) {
          case CodexThreadStarted(:final threadId):
            _live?.threadId = threadId;
          case CodexActivityEvent(:final activity):
            activityLog.upsert(activity);
          case CodexPlanEvent(:final entries):
            planLog.replace(entries);
          case CodexFileChangeEvent(:final changes):
            _recordAddedFiles(changes);
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
        failure = error is CodexExecException
            ? (error.retryable
                  ? "Couldn't start Codex on this computer. Try sending again."
                  : "Couldn't start Codex on this computer. ${error.message}")
            : friendlyCodexError('$error');
        _logRaw('$error');
      },
      onDone: () async {
        await run.done;
        settled = true;
        final reply = answer.toString().trim();
        final plan = _ref.read(agentPlanProvider);
        // A turn that laid out a plan and never finished it stalled — even with
        // a line of text, the work it promised didn't happen, so it must not
        // read as an answer (§5). Planning mode is the exception: there an
        // unfinished plan is the whole point.
        final stalled = !planFirst && agentPlanUnfinished(plan);
        final error =
            failure ??
            (stalled
                ? kAgentStalledPlan
                : (reply.isEmpty ? kAgentNoAnswer : null));
        log.finish(logId, error: error);
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

  /// Record every file Codex freshly created so the chat can offer to open it —
  /// the point of a "make me a page or a game" turn, which otherwise leaves the
  /// user a bare file path in the reply and no way to act on it (see
  /// `AgentChangesBar`). Only adds are recorded: Codex reports an edit's path but
  /// not its old contents, so an update has no honest before to diff or undo.
  void _recordAddedFiles(List<CodexFileChange> changes) {
    final changesLog = _ref.read(agentChangesProvider.notifier);
    for (final path in codexAddedPaths(changes)) {
      unawaited(_recordAddedFile(path, changesLog));
    }
  }

  /// Read the just-written file so its "before → after" diff shows the whole new
  /// file, and record it with a null [AgentChange.before] so undo deletes it. A
  /// path that can't be read (binary, or already gone) is still worth an Open, so
  /// it's recorded with no diff rather than dropped.
  Future<void> _recordAddedFile(
    String path,
    AgentChangesController changesLog,
  ) async {
    String after;
    try {
      after = await File(path).readAsString();
    } on Object {
      after = '';
    }
    changesLog.record(path: path, before: null, after: after);
  }

  /// Keep Codex's own words for the log while the chat shows the friendly line.
  ///
  /// Without this the raw reason is lost the moment it's humanized, and the log
  /// only repeats the sentence the user already read — leaving no way to tell a
  /// relay that answers no `/responses` from a rejected key or a dead network.
  void _logRaw(String raw) =>
      _ref.read(appLogProvider).failure('agent', 'codex turn failed: $raw');

  /// Ensure `~/.codex` points at [network] with [model] (idempotent, only
  /// rewritten when the grid or model changed). Returns null on success, else a
  /// user-facing error line.
  Future<String?> _pointAtGrid(NetworkCredential network, String model) async {
    final key = '${network.networkId}|$model';
    if (_ref.read(codexConfiguredProvider) == key) return null;
    final result = await _ref.read(clientAppConfiguratorProvider).apply(
      ClientApp.codex,
      network.relayBaseUrl,
      network.relayApiKey,
      [model],
    );
    if (result is ApplyError) {
      return "Couldn't point Codex at this grid: ${result.message}";
    }
    // Give Codex the web-search skill — its only way to reach the web on a grid,
    // since the relay doesn't serve the OpenAI web_search tool. A skill-install
    // hiccup must not block chatting, so its failure is swallowed here.
    try {
      await _ref.read(agentSkillInstallerProvider).install(AgentTool.codex);
    } on Object {
      // Non-fatal: Codex still chats, just without web search this session.
    }
    _ref.read(codexConfiguredProvider.notifier).set(key);
    return null;
  }
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
