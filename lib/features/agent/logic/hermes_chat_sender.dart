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
import 'agent_loop_guard.dart';
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
/// It keeps **one live `hermes acp` session per conversation**, up to
/// [kMaxLiveAgentSessions] at a time. The process is spawned once per chat, the
/// handshake runs once, and each turn sends only what the agent hasn't seen —
/// Hermes holds the conversation context itself. Switching grid, model or
/// project folder starts that chat a fresh session. The old sender re-spawned
/// the process and resent the entire history every turn, which got slower and
/// more token-hungry the longer a chat ran.
///
/// Holding one session — rather than one per chat — meant flipping between two
/// conversations put every turn back on that path, since each switch closed the
/// other's session.
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
/// between continuing it (send only what's new) and restarting it.
class _LiveSession {
  _LiveSession({required this.session, required this.key, required this.seen});

  final HermesAcpSession session;

  /// `networkId|model|conversationId` — a change in any of these means a new
  /// session (a different grid, model, or conversation).
  final String key;

  /// How many of the conversation's messages the agent has been given. A longer
  /// history next time is a continuation of the same chat (and everything past
  /// this mark goes with the next turn); anything else restarts.
  int seen;
}

class HermesChatSender implements ChatSender {
  HermesChatSender(this._ref);

  final Ref _ref;

  /// Live sessions by conversation, least recently used **first** — which is the
  /// order they get closed in. A conversation holds at most one session, and at
  /// most [kMaxLiveAgentSessions] are open at a time.
  final _live = <String, _LiveSession>{};

  /// Kill every live session — wired to the provider's dispose.
  Future<void> dispose() async {
    final open = _live.values.toList();
    _live.clear();
    for (final entry in open) {
      await entry.session.close();
    }
  }

  /// Move [slot] to the most-recently-used end. Dart maps keep insertion order,
  /// so removing and re-adding is the whole of the bookkeeping.
  void _touch(String slot) {
    final entry = _live.remove(slot);
    if (entry != null) _live[slot] = entry;
  }

  /// Close least-recently-used sessions until there is room for one more.
  Future<void> _makeRoom() async {
    while (_live.length >= kMaxLiveAgentSessions) {
      final evicted = _live.remove(_live.keys.first);
      await evicted?.session.close();
    }
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

    // Clear the shared feed now — synchronously, before the awaited setup below —
    // so the chat's "working" bubble, already on screen, can't flash the previous
    // turn's steps (or another chat's) while the session opens. See
    // [resetAgentFeed].
    resetAgentFeed(_ref);

    final pointed = await _ref
        .read(hermesGridLinkProvider)
        .point(network, model);
    if (pointed != null) {
      yield ChatSendFailure(pointed);
      return;
    }

    final HermesAcpSession session;
    final String text;
    final _LiveSession live;
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
      live = resolved.live;
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

    yield* _runTurn(session, turnText, model, planFirst: planFirst, live: live);
  }

  /// Reuse the live session when this is the next turn of the same conversation,
  /// else start a fresh one. Returns the session and the text to send — what the
  /// agent hasn't seen on a continuation, the whole history when (re)starting.
  Future<({HermesAcpSession session, String text, _LiveSession live})>
  _sessionFor(
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
    // A conversation gets one slot. The key still decides whether what's in it
    // is reusable — a chat moved to another grid, model or folder must not carry
    // on in the session that was pointed at the old one.
    final slot = conversationId ?? '';
    final live = _live[slot];
    final continues =
        live != null &&
        !live.session.isClosed &&
        live.key == key &&
        history.length > live.seen;

    if (continues) {
      _touch(slot);
      // Everything appended since the agent's last turn, not just the newest
      // message. A turn carrying a picture goes to the grid's API rather than
      // the agent, and a scheduled task's result is written straight into the
      // chat — both land here with no agent turn behind them, and sending only
      // `history.last` left the agent discussing a conversation it had half of.
      final unseen = history.sublist(live.seen);
      live.seen = history.length;
      return (
        session: live.session,
        text: buildAgentPrompt(unseen),
        live: live,
      );
    }

    // This conversation's own session is unusable — close it before replacing
    // it, then make room so opening a new one can't push the process count past
    // the cap.
    await live?.session.close();
    _live.remove(slot);
    await _makeRoom();

    final service = _ref.read(hermesAcpServiceProvider)!;
    final session = await service.start(workdir: root);
    final fresh = _LiveSession(
      session: session,
      key: key,
      seen: history.length,
    );
    _live[slot] = fresh;
    // A fresh session has no context, so replay the history into the first turn
    // — led by the project's house rules, so the agent starts on the same page.
    return (
      session: session,
      text: withProjectInstructions(buildAgentPrompt(history), instructions),
      live: fresh,
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
    required _LiveSession live,
  }) {
    // The feed was reset up front in [send], before the session setup — see
    // [resetAgentFeed]; here we only take the notifiers to append to.
    final activityLog = _ref.read(agentActivityProvider.notifier);
    final sourcesLog = _ref.read(agentSourcesProvider.notifier);
    final planLog = _ref.read(agentPlanProvider.notifier);
    final permissions = _ref.read(agentPermissionProvider.notifier);
    final log = _ref.read(commandLogProvider.notifier);
    final logId = log.begin(CliCallKind.start, 'hermes acp -m $model (agent)');

    final run = session.prompt(text);
    final answer = StringBuffer();
    final updates = StreamController<ChatSendUpdate>();
    final guard = AgentLoopGuard();
    var settled = false;
    // The two facts the stall check reads — see [agentTurnStalled]: whether
    // Hermes ended the turn itself, and whether it did any work at all. Neither
    // is reset by a plan revision: an agent ticks its boxes on the way out.
    var endedCleanly = false;
    var workedAtAll = false;
    // Hermes's own words when the turn ends in an error rather than an answer —
    // null on an ordinary turn. Held here because it arrives with the turn's end
    // and is read once the stream closes.
    String? turnError;
    Timer? idle;
    late final StreamSubscription<HermesAcpEvent> events;

    // What the assistant had produced by now — its streamed prose and the plan
    // it was working through — so a turn that fails partway keeps what it built
    // instead of wiping the chat to a bare error line. Null when there's nothing
    // to keep.
    ChatMessage? partialReply() {
      final text = answer.toString().trim();
      final plan = _ref.read(agentPlanProvider);
      if (text.isEmpty && plan.isEmpty) return null;
      return ChatMessage(
        role: ChatRole.assistant,
        text: text,
        plan: plan,
        sources: _ref.read(agentSourcesProvider),
      );
    }

    // End a turn that's gone wrong before it drags on. Mirrors the Stop path
    // (cancel + kill + log) but lands a plain line in the chat rather than
    // stopping in silence — carrying the partial work so a loop/hang cut mid-way
    // keeps what it built. [logError] is what the command log records; [failure]
    // is the line the user reads.
    Future<void> endEarly(String failure, String logError) async {
      if (settled) return;
      settled = true;
      idle?.cancel();
      await events.cancel();
      permissions.clear();
      run.kill();
      log.finish(logId, error: logError);
      updates.add(ChatSendFailure(failure, partial: partialReply()));
      await updates.close();
    }

    void stopForLoop(String stuck) =>
        unawaited(endEarly(agentLoopingMessage(stuck), 'looping ($stuck)'));

    // Catch a hung turn: the agent has sent nothing for too long and isn't
    // waiting on the user either. Re-armed by every event (below) and by every
    // answered permission; cancelled while a permission is pending, because the
    // user's own thinking time isn't the agent hanging. One turn sat silent for
    // twelve minutes after starting a dev server it then waited on forever —
    // this is what ends that instead of spinning.
    final idleTimeout = _ref.read(agentTurnIdleTimeoutProvider);
    void armIdle() {
      idle?.cancel();
      idle = Timer(
        idleTimeout,
        () => unawaited(endEarly(kAgentUnresponsive, 'unresponsive')),
      );
    }

    events = run.events.listen(
      (event) {
        switch (event) {
          case HermesAcpActivity(:final activity):
            armIdle();
            if (isAgentWork(activity)) workedAtAll = true;
            activityLog.upsert(activity);
          case HermesAcpPermission(:final request):
            // The same file or command coming back yet again is a loop, not
            // work — stop before asking the user to approve the fourth pass.
            if (guard.observe(request) case final stuck?) {
              stopForLoop(stuck);
              return;
            }
            // The agent has stopped and is waiting on the user; pause the idle
            // watch (their time isn't a hang) and re-arm it once they answer.
            idle?.cancel();
            idle = null;
            permissions.ask(request, (optionId) {
              armIdle();
              session.answerPermission(request.id, optionId);
            });
          case HermesAcpEdit(:final request):
            armIdle();
            workedAtAll = true;
            // Full access applied an edit without asking — record it so the
            // user can still undo it.
            _recordEdit(request);
            // ...and count it: a Full-access loop rewrites the same file with
            // no prompt to slow it down, so catching the repeat matters more.
            if (guard.observe(request) case final stuck?) {
              stopForLoop(stuck);
              return;
            }
          case HermesAcpSources(:final sources):
            armIdle();
            // A web look-up finished — collect its pages to cite under the
            // answer once the turn lands.
            sourcesLog.addAll(sources);
          case HermesAcpPlan(:final entries):
            armIdle();
            // The agent revised its to-do list — replace ours with its latest.
            planLog.replace(entries);
          case HermesAcpMessage(:final text):
            armIdle();
            answer.write(text);
            updates.add(ChatSendStreaming(answer.toString()));
          case HermesAcpTurnEnded(endedCleanly: final clean, :final error):
            endedCleanly = clean;
            turnError = error;
        }
      },
      onDone: () async {
        await run.done;
        settled = true;
        idle?.cancel();
        // Nothing is waiting on an answer once the turn is over — a card left
        // pinned in the chat would be a button that does nothing.
        permissions.clear();

        final reply = answer.toString().trim();
        // Hermes answers with its own failure when the model won't take the turn
        // — a build that can't resolve the grid's named provider, the grid's
        // failed HTTP call, or its loop giving up on an empty/unparseable
        // response (`API call failed after 3 retries: Expecting value…`). All
        // are errors, not answers — show them as one, and keep the raw text in
        // the log to diagnose from.
        final refused =
            friendlyAgentUnknownProvider(reply) ??
            friendlyAgentServerError(reply) ??
            friendlyAgentEmptyResponse(reply);
        if (refused != null) _ref.read(appLogProvider).failure('agent', reply);
        // A turn that announced a plan and stopped before doing it must not read
        // as an answer (§5) — but an unfinished plan alone doesn't mean that, so
        // the verdict weighs how the turn ended and what it did (see
        // [agentTurnStalled]). Shared with Codex so a stalled turn reads the same
        // whichever agent ran it.
        final plan = _ref.read(agentPlanProvider);
        final stalled = agentTurnStalled(
          plan: plan,
          endedCleanly: endedCleanly,
          workedAtAll: workedAtAll,
          planFirst: planFirst,
        );
        if (stalled) {
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
        // A turn that ended in an error had nothing to answer with, so it takes
        // precedence over "no answer": that line is for an agent that ran and
        // said nothing, and using it here left the reason — a model Hermes can't
        // be pointed at — invisible in the chat and in the log.
        final failed = turnError == null
            ? null
            : (friendlyAgentUnknownProvider(turnError!) ??
                  friendlyAgentServerError(turnError!) ??
                  kAgentTurnFailed);
        final failure =
            refused ??
            failed ??
            (stalled
                ? kAgentStalledPlan
                : (reply.isEmpty ? kAgentNoAnswer : null));

        log.finish(logId, error: failure);
        // The answer is about to be appended to the chat, and the agent wrote it
        // — so it already knows it. Counting it here keeps the next turn from
        // quoting the agent's own words back at it as "context you missed".
        // Only on success: a failed turn appends nothing.
        if (failure == null) live.seen++;
        // A failed turn still kept the prose/plan it built, unless the "reply"
        // was itself the raw failure we humanized (`refused`) — that isn't
        // content, so there's nothing to keep.
        updates.add(
          failure != null
              ? ChatSendFailure(
                  failure,
                  partial: refused != null ? null : partialReply(),
                )
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

    // Nothing has arrived yet, so start the idle watch now — a turn that never
    // says a word is as stuck as one that goes quiet mid-way.
    armIdle();

    // The user hit Stop (or left the chat). A clean finish lands here too — via
    // the close above, with [settled] already set — and must *not* tear the
    // session down: the next turn reuses it.
    updates.onCancel = () async {
      idle?.cancel();
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
