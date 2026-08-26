import 'dart:async';
import '../../../../infrastructure/cli/model_control_tokens.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/cli/command_log.dart';
import '../../../../infrastructure/logging/app_log.dart';
import '../../../../infrastructure/cli/hermes_acp_service.dart';
import '../../../../infrastructure/cli/hermes_acp_setup.dart';
import '../../../../infrastructure/cli/hermes_config_file.dart';
import '../../../../infrastructure/state/chat_prefs_store.dart';
import '../../../../infrastructure/state/models/network_credential.dart';
import '../../../../shared/copy/setup_hints.dart';
import '../../../playground/logic/chat_message.dart';
import '../../../playground/logic/chat_sender.dart';
import '../../../playground/logic/playground_request.dart';
import '../../../../infrastructure/cli/agent_event.dart';
import '../../../../infrastructure/cli/agent_resume_point.dart';
import '../../../../infrastructure/state/model_context_store.dart';
import '../acp_images.dart';
import '../agent_changes.dart';
import '../agent_server_error.dart';
import '../agent_permissions.dart';
import '../agent_steering.dart';
import '../agent_prompt.dart';
import 'agent_turn_env.dart';
import 'hermes_grid_link.dart';
import 'hermes_tool.dart';
import '../agent_providers.dart';

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
/// ACP streams `tool_call` / `agent_message_chunk` updates, so this feeds that
/// conversation's live run ([agentRunsProvider]) and streams the answer into the
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
    // Hermes serves a live ACP process, not a spawn-env per turn, so the
    // per-turn X-Request-Id header is not threaded through its env today.
    // ponytail: wire via the hermes config `extra_headers` when turn-level
    // usage on the Hermes lane is needed.
    String? turnId,
    String? instructions,
    // Hermes' ACP server advertises nine commands and `goal` is not among
    // them; an unknown one falls through to the model as prose — see
    // GoalOwner.app. Not supported.
    String? agentCommand,
    bool planFirst = false,
    AgentApprovalMode? approval,
    // Hermes holds its conversation in a live ACP process rather than in a file
    // it can be pointed back at, so there is no session here to resume: when
    // that process is gone, so is the session.
    AgentResumePoint? resume,
  }) async* {
    if (modality != PlaygroundModality.text) {
      yield const ChatSendFailure('The agent can only answer in text.');
      return;
    }
    if (_ref.read(hermesAcpServiceProvider) == null) {
      yield ChatSendFailure(notSetUpToMessage('answer chats'));
      return;
    }
    if (history.isEmpty || history.last.text.trim().isEmpty) {
      yield const ChatSendFailure('Nothing to send.');
      return;
    }

    // Everything this turn publishes is filed under its conversation, so two
    // chats answering at once never show each other's work.
    final chat = conversationId ?? '';
    // Clear this chat's feed now — synchronously, before the awaited setup below
    // — so its "working" bubble, already on screen, can't flash the previous
    // turn's steps while the session opens. See [AgentRuns.reset].
    _ref.read(agentRunsProvider.notifier).reset(chat);

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
      // Stamp this turn's id into Hermes's config so the NEXT Hermes process
      // reads it into its request `extra_headers` at agent build. Hermes reads
      // the config when it changes (mtime cache) but bakes the headers into the
      // OpenAI client once at session build — so a turn with an id must open a
      // fresh session (history is replayed, so the conversation continues).
      // That re-spawn + full-history replay every turn is the deliberate cost of
      // per-turn attribution for Hermes; leave this block if that feels heavy.
      if (turnId != null && turnId.isNotEmpty) {
        try {
          await HermesConfigFile().setTurnRequestHeader(
            gridBaseUrl: network.relayBaseUrl,
            turnId: turnId,
          );
        } on Object {
          // A config write must never take the turn down — on a miss the turn
          // simply runs without a turn id.
        }
      }
      final resolved = await _sessionFor(
        network,
        model,
        conversationId,
        history,
        workdir,
        instructions,
        forceFresh: turnId != null && turnId.isNotEmpty,
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

    // This turn runs under the mode its *chat* was set to when Send was pressed
    // — switching the mode takes effect on the next message, not the next
    // session, and another chat's mode never reaches this one. Plan mode has two
    // shapes: the planning turn is forced read-only (it must touch nothing), and
    // the execute turn that follows an approval carries out the plan asking per
    // action — so `plan` maps to `ask` there.
    final mode = approval ?? _ref.read(chatPrefsProvider).approval;
    session.approvalMode = planFirst
        ? AgentApprovalMode.readOnly
        : (mode == AgentApprovalMode.plan ? AgentApprovalMode.ask : mode);
    final turnText = planFirst ? withPlanPreamble(text) : text;

    // Hand the session's id to the caller: Hermes names its own sessions, and
    // the Chat tab uses that name for the conversation once it lands.
    if (session.sessionId case final id?) yield ChatSendAgentSession(id);

    yield* _runTurn(
      session,
      turnText,
      model,
      planFirst: planFirst,
      live: live,
      chat: chat,
      attachments: attachments,
    );
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
    String? instructions, {
    bool forceFresh = false,
  }) async {
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
        !forceFresh &&
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
        // The pictures on this turn ride beside the prompt as bytes, so this
        // must not also send the agent off to open them on disk.
        text: buildAgentPrompt(unseen, opensAttachments: false),
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
    // Hands the conversation id to the process as GRID_CHAT_ID, so a task the
    // agent schedules mid-chat knows which thread to deliver its answer into
    // (see gridTurnEnv) — and, on the relay side, so this turn's calls carry
    // the header that attributes them to this conversation.
    final session = await service.start(
      workdir: root,
      extraEnv: gridTurnEnv(conversationId),
    );
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
      text: withProjectInstructions(
        buildAgentPrompt(history, opensAttachments: false),
        instructions,
      ),
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
    required String chat,
    required List<MediaAttachment> attachments,
  }) {
    // The feed was reset up front in [send], before the session setup — see
    // [AgentRuns.reset]; here we only take the notifiers to append to.
    final runs = _ref.read(agentRunsProvider.notifier);
    final permissions = _ref.read(agentPermissionsProvider.notifier);
    final log = _ref.read(commandLogProvider.notifier);
    // No argv to show: the turn is a prompt over an ACP session that is already
    // running, so what it carried is the text itself (the model is on the line).
    final logId = log.begin(
      CliCallKind.start,
      'hermes acp -m $model (agent)',
      detail: CommandDetail(requestBody: text),
    );

    final run = session.prompt(text, images: acpImages(attachments));
    // Anything typed in this chat while the turn runs goes into the turn itself
    // (the adapter's `/steer`), not into a queue behind it, and is recorded in
    // the turn's timeline where it happened (see [AgentSteeringController]).
    final steering = _ref.read(agentSteeringProvider.notifier);
    steering.offer(chat, session.steer);

    final answer = StringBuffer();
    // What the agent has said, with any chat-template marker cut off it — a
    // model served over the grid can overrun its stop token and carry on into a
    // turn of its own invention (see [stripControlTokens]). Read through this
    // rather than off the buffer, so the streamed reply, the saved one and the
    // one a failed turn keeps are the same text.
    String said() => stripControlTokens(answer.toString());
    final updates = StreamController<ChatSendUpdate>();
    var settled = false;
    // The two facts the stall check reads — see [agentTurnStalled]: whether
    // Hermes ended the turn itself, and whether it did any work at all. Neither
    // is reset by a plan revision: an agent ticks its boxes on the way out.
    var endedCleanly = false;
    var workedAtAll = false;
    // How many tools the turn called, read off its ending — the one number that
    // separates an agent that finished from one Hermes cut off at its budget.
    var turnCalls = 0;
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
      final text = said().trim();
      final plan = _ref.read(agentRunProvider(chat)).plan;
      if (text.isEmpty && plan.isEmpty) return null;
      return ChatMessage(
        role: ChatRole.assistant,
        text: text,
        plan: plan,
        sources: _ref.read(agentRunProvider(chat)).sources,
      );
    }

    // Note a turn that has gone quiet — nothing sent for a long stretch, and not
    // waiting on the user either. Re-armed by every event (below) and by every
    // answered permission; cancelled while a permission is pending, because the
    // user's own thinking time isn't the agent going quiet.
    //
    // A note in the log, and nothing else: the app doesn't end a turn the agent
    // hasn't ended. Silence is not proof of a hang — a long install, a full test
    // suite and a slow model all look exactly like it, and the turns this used to
    // cut were working. What the user sees is the working bubble's own clock, and
    // Stop is theirs to press.
    final idleTimeout = _ref.read(agentTurnIdleTimeoutProvider);
    void armIdle() {
      idle?.cancel();
      idle = Timer(idleTimeout, () {
        if (settled) return;
        _ref
            .read(appLogProvider)
            .warn(
              'agent',
              'turn quiet for ${idleTimeout.inMinutes}m — still running',
            );
      });
    }

    events = run.events.listen(
      (event) {
        switch (event) {
          case HermesAcpActivity(:final activity):
            armIdle();
            if (isAgentWork(activity)) workedAtAll = true;
            // With what has been said so far, so the step lands *after* that
            // passage in the turn's timeline rather than under the whole answer.
            runs.upsertStep(chat, activity, answer: said());
          case HermesAcpContextUsed(:final size):
            // Hermes probes the provider for this and caches it; the relay
            // advertises `null` for some of the same models. Feeding it to the
            // shared store means one lane's measurement corrects every lane's
            // guess — `learnedModelContextProvider` is what
            // `modelContextWindowProvider` reads, so the Claude and Codex lanes
            // pick this up for the same model without asking Hermes anything.
            //
            // Hermes reports the window of whichever node it is on, so `learn`
            // keeps the smallest ever seen — a roomier node must not raise the
            // figure a tighter one has to live with.
            _ref.read(learnedModelContextProvider.notifier).learn(model, size);
          case HermesAcpPermission(:final request):
            // The agent has stopped and is waiting on the user; pause the idle
            // watch (their time isn't a hang) and re-arm it once they answer.
            idle?.cancel();
            idle = null;
            permissions.ask(chat, request, (optionId) {
              armIdle();
              session.answerPermission(request.id, optionId);
            });
          case HermesAcpEdit(:final request):
            armIdle();
            workedAtAll = true;
            // Full access applied an edit without asking — record it so the
            // user can still undo it.
            _recordEdit(chat, request);
          case HermesAcpSources(:final sources):
            armIdle();
            // A web look-up finished — collect its pages to cite under the
            // answer once the turn lands.
            runs.addSources(chat, sources);
          case HermesAcpPlan(:final entries):
            armIdle();
            // The agent revised its to-do list — replace ours with its latest.
            runs.setPlan(chat, entries);
          case HermesAcpMessage(:final text):
            armIdle();
            answer.write(text);
            updates.add(ChatSendStreaming(said()));
          case HermesAcpTurnEnded(
            endedCleanly: final clean,
            :final toolCalls,
            :final error,
          ):
            endedCleanly = clean;
            turnCalls = toolCalls;
            turnError = error;
        }
      },
      onDone: () async {
        await run.done;
        settled = true;
        idle?.cancel();
        // Nothing is waiting on an answer once the turn is over — a card left
        // pinned in the chat would be a button that does nothing, and a message
        // typed from here belongs to the next turn.
        permissions.clear(chat);
        steering.withdraw(chat);

        final reply = said().trim();
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
        // A turn that announced a plan and stopped before finishing it is worth
        // recording — but only recording. The verdict is a guess about work the
        // app can't see, and calling a finished answer a failure on the strength
        // of an unticked box put an error over turns that had answered (§5).
        final plan = _ref.read(agentRunProvider(chat)).plan;
        // Ran out of room rather than out of work. Recorded with the numbers
        // behind the verdict, because the line the user reads carries neither.
        final outOfSteps = agentSpentToolBudget(
          toolCalls: turnCalls,
          budget: kHermesToolCallBudget,
          plan: plan,
        );
        if (outOfSteps) {
          _ref
              .read(appLogProvider)
              .warn(
                'agent',
                'turn hit its tool-call budget ($turnCalls call(s), budget '
                    '$kHermesToolCallBudget) with its plan unfinished — Hermes '
                    'made it summarize',
              );
        }
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
        // A turn that ended in an error had nothing to answer with, so it takes
        // precedence over "no answer": that line is for an agent that ran and
        // said nothing, and using it here left the reason — a model Hermes can't
        // be pointed at — invisible in the chat and in the log.
        final failed = turnError == null
            ? null
            : (friendlyAgentLostContact(turnError!) ??
                  friendlyAgentUnknownProvider(turnError!) ??
                  friendlyAgentServerError(turnError!) ??
                  kAgentTurnFailed);
        final failure =
            refused ?? failed ?? (reply.isEmpty ? kAgentNoAnswer : null);
        // The grid turned this key away. Whatever the reason, the config the app
        // wrote for Hermes is the suspect — so drop the memo that says it's
        // current, and the next message rewrites it from `~/.grid` (and clears
        // out credentials left behind for other grids on the way). Reached from
        // both halves: Hermes reports the failed call as the answer on some
        // paths and as the turn's error on others.
        if (isGridKeyRefusal(reply) ||
            (turnError != null && isGridKeyRefusal(turnError!))) {
          _ref.read(hermesGridLinkProvider).forgetPointing();
        }

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
                    sources: _ref.read(agentRunProvider(chat)).sources,
                    plan: plan,
                  ),
                  // Hermes reports a turn it capped as an ordinary end_turn, so
                  // this is the only place the chat can learn the answer above
                  // is a summary written under protest rather than the finished
                  // work (see [agentSpentToolBudget]).
                  outOfSteps: outOfSteps,
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
      steering.withdraw(chat);
      if (settled) return;
      permissions.clear(chat);
      run.kill();
      log.finish(logId, error: 'stopped');
    };
    return updates.stream;
  }

  /// Record an edit [chat]'s agent made so it can be undone. A create has no old
  /// text (undo deletes the file); a change carries the original to restore.
  void _recordEdit(String chat, AgentPermission request) {
    final path = request.path;
    if (path == null || path.isEmpty) return;
    _ref
        .read(agentChangesProvider.notifier)
        .record(
          chatId: chat,
          path: path,
          before: request.oldText,
          after: request.newText ?? '',
        );
  }
}
