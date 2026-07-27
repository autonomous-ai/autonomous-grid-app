import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/command_log.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../../infrastructure/cli/hermes_acp_service.dart';
import '../../../infrastructure/cli/hermes_acp_setup.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../playground/logic/chat_message.dart';
import '../../playground/logic/chat_sender.dart';
import '../../playground/logic/playground_request.dart';
import '../../../infrastructure/cli/agent_event.dart';
import 'agent_changes.dart';
import 'agent_server_error.dart';
import 'agent_permissions.dart';
import 'agent_prompt.dart';
import 'hermes_grid_link.dart';
import 'hermes_tool.dart';
import 'agent_providers.dart';

/// The hermes ACP seam, or null when hermes is absent.
///
/// Wrapped in [RepairingHermesAcpService] so a Hermes installed without its ACP
/// support finishes installing itself on the first turn that needs it, rather
/// than failing every turn until the user reinstalls — which reinstalled it just
/// as broken (see [friendlyAgentStartupError]).
final hermesAcpServiceProvider = Provider<HermesAcpService?>((ref) {
  final path = ref.watch(hermesPathProvider);
  if (path == null) return null;
  // The real logger, not the default no-op: permission decisions are exactly
  // what a user's bug report has to be able to show us.
  final log = ref.watch(appLogProvider);
  final service = HermesAcpServiceImpl(path, log: log);
  final setup = ref.watch(hermesAcpSetupProvider);
  return setup == null
      ? service
      : RepairingHermesAcpService(service, setup, log: log);
});

/// The chat's default [ChatSender], backed by Hermes over ACP (Agent Client
/// Protocol).
///
/// It keeps **one live `hermes acp` session per conversation**. The process is
/// spawned once, the handshake runs once, and each turn sends only the new
/// message — Hermes holds the conversation context itself. Switching
/// conversation, grid or model starts a fresh session. The old sender re-spawned
/// the process and resent the entire history every turn, which got slower and
/// more token-hungry the longer a chat ran.
///
/// ACP streams `tool_call` / `agent_message_chunk` updates, so this feeds the
/// live activity feed ([agentActivityProvider]) and streams the answer into the
/// bubble as it's generated.
final hermesChatSenderProvider = Provider<ChatSender>((ref) {
  final sender = HermesChatSender(ref);
  ref.onDispose(sender.dispose);
  return sender;
});

/// A live Hermes session and what it has already seen, so the sender can decide
/// between continuing it (send only the new turn) and restarting it.
class _LiveSession {
  _LiveSession({required this.session, required this.key, required this.seen});

  final HermesAcpSession session;

  /// `networkId|model|conversationId` — a change in any of these means a new
  /// session (a different grid, model, or conversation).
  final String key;

  /// The history length at the last prompt. A longer history next time is a
  /// continuation of the same chat; anything else restarts.
  int seen;
}

class HermesChatSender implements ChatSender {
  HermesChatSender(this._ref);

  final Ref _ref;
  _LiveSession? _live;

  /// Kill any live session — wired to the provider's dispose.
  Future<void> dispose() async {
    await _live?.session.close();
    _live = null;
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
  }) async* {
    if (modality != PlaygroundModality.text) {
      yield const ChatSendFailure('The agent can only answer in text.');
      return;
    }
    if (_ref.read(hermesAcpServiceProvider) == null) {
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

    final pointed = await _ref
        .read(hermesGridLinkProvider)
        .point(network, model);
    if (pointed != null) {
      yield ChatSendFailure(pointed);
      return;
    }

    final HermesAcpSession session;
    final String text;
    try {
      final resolved = await _sessionFor(
        network,
        model,
        conversationId,
        history,
        workdir,
        instructions,
      );
      session = resolved.session;
      text = resolved.text;
    } on HermesAcpException catch (e) {
      // Only suggest retrying when retrying could work. A machine missing a
      // dependency fails identically every time, so it gets a plain, actionable
      // line instead — Hermes's raw stderr ("pip install …") means nothing to a
      // non-technical user, and the raw reason is already in the log.
      yield ChatSendFailure(
        e.retryable
            ? "Couldn't start the assistant on this computer. Try sending again."
            : friendlyAgentStartupError(e.message),
      );
      return;
    }

    // This turn runs under whatever the user has the composer set to *now* —
    // switching the mode takes effect on the next message, not the next session.
    // Plan mode has two shapes: the planning turn is forced read-only (it must
    // touch nothing), and the execute turn that follows an approval carries out
    // the plan asking per action — so `plan` maps to `ask` there.
    final mode = _ref.read(agentApprovalModeProvider);
    session.approvalMode = planFirst
        ? AgentApprovalMode.readOnly
        : (mode == AgentApprovalMode.plan ? AgentApprovalMode.ask : mode);
    final turnText = planFirst ? withPlanPreamble(text) : text;

    // Hand the session's id to the caller: Hermes names its own sessions, and
    // the Chat tab uses that name for the conversation once it lands.
    if (session.sessionId case final id?) yield ChatSendAgentSession(id);

    yield* _runTurn(session, turnText, model, planFirst: planFirst);
  }

  /// Reuse the live session when this is the next turn of the same conversation,
  /// else start a fresh one. Returns the session and the text to send — only the
  /// new user turn on a continuation, the whole history when (re)starting.
  Future<({HermesAcpSession session, String text})> _sessionFor(
    NetworkCredential network,
    String model,
    String? conversationId,
    List<ChatMessage> history,
    String? workdir,
    String? instructions,
  ) async {
    // The folder is part of the key: moving a chat to another project must start
    // a fresh session, or the agent would keep reading the old folder.
    final root = workdir ?? _ref.read(agentWorkspaceDirProvider).path;
    final key = '${network.networkId}|$model|$conversationId|$root';
    final live = _live;
    final continues =
        live != null &&
        !live.session.isClosed &&
        live.key == key &&
        history.length > live.seen;

    if (continues) {
      live.seen = history.length;
      return (session: live.session, text: history.last.text.trim());
    }

    await live?.session.close();
    final service = _ref.read(hermesAcpServiceProvider)!;
    final session = await service.start(workdir: root);
    _live = _LiveSession(session: session, key: key, seen: history.length);
    // A fresh session has no context, so replay the history into the first turn
    // — led by the project's house rules, so the agent starts on the same page.
    return (
      session: session,
      text: withProjectInstructions(buildAgentPrompt(history), instructions),
    );
  }

  /// Run one turn: stream the answer into the bubble as it arrives, mirror tool
  /// steps into the activity feed, put the agent's permission requests to the
  /// user, and end with the finished reply.
  ///
  /// Driven by an explicit subscription rather than `await for` inside an
  /// `async*`: a generator suspended on `await for` isn't torn down until its
  /// source emits again, so Stop would leave the agent running (and a permission
  /// card pinned) until it happened to say something. Here, cancelling the
  /// stream kills the turn there and then.
  Stream<ChatSendUpdate> _runTurn(
    HermesAcpSession session,
    String text,
    String model, {
    required bool planFirst,
  }) {
    final activityLog = _ref.read(agentActivityProvider.notifier)..clear();
    final sourcesLog = _ref.read(agentSourcesProvider.notifier)..clear();
    final planLog = _ref.read(agentPlanProvider.notifier)..clear();
    final permissions = _ref.read(agentPermissionProvider.notifier);
    final log = _ref.read(commandLogProvider.notifier);
    final logId = log.begin(CliCallKind.start, 'hermes acp -m $model (agent)');

    final run = session.prompt(text);
    final answer = StringBuffer();
    final updates = StreamController<ChatSendUpdate>();
    var settled = false;

    final events = run.events.listen(
      (event) {
        switch (event) {
          case HermesAcpActivity(:final activity):
            activityLog.upsert(activity);
          case HermesAcpPermission(:final request):
            // The agent has stopped and is waiting on the user; their answer
            // goes straight back down the same session.
            permissions.ask(
              request,
              (optionId) => session.answerPermission(request.id, optionId),
            );
          case HermesAcpEdit(:final request):
            // Full access applied an edit without asking — record it so the
            // user can still undo it.
            _recordEdit(request);
          case HermesAcpSources(:final sources):
            // A web look-up finished — collect its pages to cite under the
            // answer once the turn lands.
            sourcesLog.addAll(sources);
          case HermesAcpPlan(:final entries):
            // The agent revised its to-do list — replace ours with its latest.
            planLog.replace(entries);
          case HermesAcpMessage(:final text):
            answer.write(text);
            updates.add(ChatSendStreaming(answer.toString()));
        }
      },
      onDone: () async {
        await run.done;
        settled = true;
        // Nothing is waiting on an answer once the turn is over — a card left
        // pinned in the chat would be a button that does nothing.
        permissions.clear();

        final reply = answer.toString().trim();
        // Hermes answers with the grid's failed HTTP call when the model won't
        // take the turn. That's an error, not an answer — show it as one, and
        // keep the raw envelope in the log to diagnose from.
        final refused = friendlyAgentServerError(reply);
        if (refused != null) _ref.read(appLogProvider).failure('agent', reply);
        // A turn that laid out a plan and never finished it stalled — even with
        // a line of text, the work it promised didn't happen, so it must not
        // read as an answer (§5). Planning mode is the exception: there an
        // unfinished plan is the whole point. Shared with Codex so a stalled
        // turn reads the same whichever agent ran it.
        final plan = _ref.read(agentPlanProvider);
        final stalled = !planFirst && agentPlanUnfinished(plan);
        final failure =
            refused ??
            (stalled
                ? kAgentStalledPlan
                : (reply.isEmpty ? kAgentNoAnswer : null));

        log.finish(logId, error: failure);
        updates.add(
          failure != null
              ? ChatSendFailure(failure)
              : ChatSendSuccess(
                  ChatMessage(
                    role: ChatRole.assistant,
                    text: reply,
                    sources: _ref.read(agentSourcesProvider),
                    plan: plan,
                  ),
                ),
        );
        await updates.close();
      },
    );

    // The user hit Stop (or left the chat). A clean finish lands here too — via
    // the close above, with [settled] already set — and must *not* tear the
    // session down: the next turn reuses it.
    updates.onCancel = () async {
      await events.cancel();
      if (settled) return;
      permissions.clear();
      run.kill();
      log.finish(logId, error: 'stopped');
    };
    return updates.stream;
  }

  /// Record an edit the agent made so it can be undone. A create has no old text
  /// (undo deletes the file); a change carries the original to restore.
  void _recordEdit(AgentPermission request) {
    final path = request.path;
    if (path == null || path.isEmpty) return;
    _ref
        .read(agentChangesProvider.notifier)
        .record(
          path: path,
          before: request.oldText,
          after: request.newText ?? '',
        );
  }
}
