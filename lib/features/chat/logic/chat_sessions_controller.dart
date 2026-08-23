import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'turn_model_usage.dart';
import '../../../core/app_environment.dart';
import '../../../core/text_preview.dart';
import '../../../infrastructure/api/chat_transport.dart';
import '../../../infrastructure/api/models/grid_overview.dart';
import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/cli/agent_resume_point.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../../infrastructure/platform/desktop_notifier.dart';
import '../../../infrastructure/platform/window_focus.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../agents/logic/agent_changes.dart';
import '../../agents/logic/agent_questions.dart';
import '../../agents/logic/agent_providers.dart';
import '../../agents/logic/agent_routing.dart';
import '../../agents/logic/hermes_vision_controller.dart';
import '../../agents/logic/agent_session_title.dart';
import '../../agents/logic/active_chat_agent.dart';
import '../../agents/logic/agent_catalog.dart';
import '../../agents/logic/agent_status.dart';
import '../../agents/logic/adapters/claude_chat_sender.dart';
import '../../agents/logic/agent_steering.dart';
import '../../agents/logic/auto_agent_router.dart';
import '../../network/logic/node_display.dart' show kAutoModelId;
import '../../auth/logic/session_controller.dart';
import '../../playground/logic/chat_message.dart';
import '../../playground/logic/chat_sender.dart';
import '../../network/logic/grid_overview_provider.dart';
import '../../playground/logic/media_outputs.dart';
import '../../playground/logic/one_shot_target.dart';
import '../../playground/logic/playground_models.dart';
import '../../playground/logic/playground_request.dart';
import '../../projects/logic/project.dart';
import 'chat_title.dart';
import 'chat_title_writer.dart';
import 'commands/agent_ask_block.dart';
import 'commands/chat_command.dart';
import 'commands/chat_compaction.dart';
import 'commands/chat_goal.dart';
import 'commands/chat_loop.dart';
import 'commands/loop_pace_block.dart';
import 'commands/schedule_argument.dart';
import '../../scheduled/logic/scheduled_jobs_controller.dart';
import '../../scheduled/logic/task_destination.dart';
import '../../scheduled/logic/task_runner.dart';
import 'chat_sessions_state.dart';
import 'chat_store.dart';
import 'conversation.dart';
import 'interrupted_turn.dart';
import 'loop_claim.dart';

/// Re-exported so every file that already imports the controller keeps seeing
/// [ChatSessionsState] — moving the state out is not a change any caller has to
/// hear about.
export 'chat_sessions_state.dart';

part 'chat_sessions_goals.dart';
part 'chat_sessions_loops.dart';
part 'chat_sessions_queue.dart';
part 'chat_sessions_send.dart';
part 'chat_sessions_settle.dart';

/// Drives the persistent Chat tab. Loads saved conversations on start, and on
/// each send appends the turn to the sending conversation and writes it to disk
/// via [ChatStore]. The actual dispatch is delegated to the shared [ChatSender]
/// so text/image/video routing and error copy match the Playground exactly.
///
/// Sends are tracked per conversation ([_subs]/[_dones] keyed by id), so several
/// chats can be generating replies at once and starting or switching chats is
/// never blocked by one that is still streaming.
final chatSessionsProvider =
    NotifierProvider<ChatSessionsController, ChatSessionsState>(
      ChatSessionsController.new,
    );

/// How long a loop iteration may go with no progress before it is treated as
/// hung. A seam over [kLoopTurnStall] so a test can shorten the wait instead of
/// holding a stalled turn for the full hour.
final loopTurnStallProvider = Provider<Duration>((ref) => kLoopTurnStall);

/// How long a resumed loop waits before an overdue turn goes out. A seam over
/// [kLoopResumeSettle] so a test doesn't hold the clock for the settle.
final loopResumeSettleProvider = Provider<Duration>((ref) => kLoopResumeSettle);

/// The gap a continuous loop leaves between turns. A seam over
/// [kContinuousLoopGap] so a test can drive back-to-back turns without the
/// three-second settle in between.
final loopContinuousGapProvider = Provider<Duration>(
  (ref) => kContinuousLoopGap,
);

/// Everything needed to repeat a failed turn without asking the user to rebuild
/// its text, pictures, documents, or captured context in the composer.
class _RetryableTurn {
  const _RetryableTurn({
    required this.messageCount,
    required this.attachments,
    required this.planTurn,
    required this.continuedAgent,
  });

  /// The transcript length after the user turn was committed. A partial answer
  /// may follow it after failure; retry trims to this point before sending.
  final int messageCount;

  final List<MediaAttachment> attachments;
  final bool planTurn;
  final AgentTool? continuedAgent;
}

/// How a turn ended, for the goal loop to judge: what the assistant said, why
/// it failed if it did, and whether it actually did any work.
///
/// [ranSteps] is the stall guard's evidence — a turn that only produced prose
/// moved nothing, and three of those in a row is a loop, not thinking.
typedef _TurnOutcome = ({String? reply, String? failure, bool ranSteps});

/// The plumbing the Chat tab's five jobs share — running a turn, settling it,
/// holding what the user typed behind it, driving a goal, and repeating a
/// prompt on a timer.
///
/// They live in files of their own (§4) and reach the same state through this
/// spine. What is left `abstract` below is exactly the set of calls those five
/// make into each other: naming them in one place is what keeps the seams
/// visible instead of hiding a cycle inside one 1,400-line class.
abstract class _ChatSessions extends Notifier<ChatSessionsState> {
  /// One live subscription per streaming conversation, so [stop] and disposal
  /// tear down exactly the one they mean and each reply folds into its own chat.
  final Map<String, StreamSubscription<ChatSendUpdate>> _subs = {};
  final Map<String, Completer<void>> _dones = {};

  /// The last attempted turn per chat. Kept in memory only: errors are live
  /// state too, and without an error there is no Retry action that can read it.
  final Map<String, _RetryableTurn> _retryableTurns = {};

  /// Naming a chat outlives the send it started in (the agent writes the name
  /// seconds later), so it has to know when there's no longer a state to write.
  bool _disposed = false;

  /// How the last turn of each chat ended, so the goal loop can judge it
  /// without the update stream having to carry it there. Written as the turn
  /// lands, read and dropped as it settles; absent means the turn was stopped
  /// rather than finished.
  final Map<String, _TurnOutcome> _lastTurn = {};

  /// Consecutive judged turns that did no work, per chat — the stall guard's
  /// counter. In memory only: a goal that survives a restart comes back
  /// stalled anyway.
  final Map<String, int> _idleGoalTurns = {};

  /// The pending wake-up of each repeating prompt. In memory by nature, and
  /// cancelled on disposal — a timer that outlives its controller fires into a
  /// state that is no longer there.
  final Map<String, Timer> _loopTimers = {};

  /// When each in-flight turn last showed progress — a streamed chunk or a
  /// status change. The loop reads it to tell a turn that is working from one
  /// that has hung (see [kLoopTurnStall]); in memory, like the turn itself.
  final Map<String, DateTime> _turnActivityAt = {};

  /// The chats with a naming attempt in flight. Naming is retried on every turn
  /// until it lands, and an attempt can take longer than a short turn does — so
  /// without this a chat answered three times in a minute would have three of
  /// them running, each waiting out the same poll and each spending its own
  /// request.
  final Set<String> _naming = {};

  ChatStore get _store => ref.read(chatStoreProvider);

  /// The open conversation, or a fresh (unsaved) one seeded with [model] and the
  /// project the user started it in.
  Conversation _activeOrNew(String model) {
    final active = state.active;
    if (active != null) return active;
    final now = DateTime.now();
    return Conversation(
      id: now.microsecondsSinceEpoch.toString(),
      title: kNewConversationTitle,
      model: model,
      createdAt: now,
      updatedAt: now,
      projectId: state.draftProjectId,
    );
  }

  /// The chat `/goal` and `/loop` act on: the one that is open, or the compose
  /// the user is standing in, started here and now.
  ///
  /// A chat is not saved until its first message, so either command typed into
  /// a fresh composer used to be answered with "Open a chat first" — a refusal
  /// to do something there was no reason not to do. As far as anything on
  /// screen says the user *is* in a chat, and Claude Code takes both from the
  /// first line of a session. The turn the command fires next is what fills the
  /// chat in and names it.
  Conversation _startedChat(String model) {
    final open = state.active;
    if (open != null) return open;
    final started = _activeOrNew(model);
    _commit(started, phase: const SendIdle(), makeActive: true);
    return started;
  }

  Conversation? _find(String id) {
    for (final c in state.conversations) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Swap one conversation in place, keeping the rest of the state as-is.
  /// Deliberately does not re-sort: archiving and unarchiving both leave
  /// [Conversation.updatedAt] alone, so the list order is already right.
  void _replace(Conversation conversation, {required String? activeId}) {
    state = state.copyWith(
      conversations: [
        for (final c in state.conversations)
          if (c.id == conversation.id) conversation else c,
      ],
      activeId: activeId,
    );
  }

  /// Persist [conversation] and publish it where it already sits.
  ///
  /// The one move behind every edit that is not talking — renaming, pinning,
  /// picking a model, archiving: write it, swap it in, leave `updatedAt`
  /// and the open chat alone so the sidebar never re-sorts for a change the
  /// user would not call a message.
  void _saveAndReplace(Conversation conversation) {
    _store.save(conversation);
    _replace(conversation, activeId: state.activeId);
  }

  /// Upsert [conversation], re-sort newest-first, set its send [phase], and
  /// persist. [makeActive] opens it (used when the user sends into it); a reply
  /// landing in a background chat leaves it false so focus stays put.
  /// [awaitingPlan] lights that chat's plan-approval bar — set only after a
  /// planning turn's reply lands, and default-off everywhere else so any other
  /// commit (a new send, a stopped turn) clears it. Every commit clears that
  /// chat's prior error.
  void _commit(
    Conversation conversation, {
    required SendPhase phase,
    bool awaitingPlan = false,
    bool outOfSteps = false,
    bool makeActive = false,
  }) {
    // Talking in a chat un-files it. Reaching an archived chat takes opening it
    // from the Archived screen, and once the user types into it, leaving it
    // hidden would mean their reply lands somewhere the sidebar never shows —
    // the chat would look lost the moment they navigated away.
    final saved = conversation.isArchived
        ? conversation.copyWith(clearArchivedAt: true)
        : conversation;
    _store.save(saved);
    final list = [
      saved,
      for (final c in state.conversations)
        if (c.id != saved.id) c,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    state = state
        .copyWith(
          conversations: list,
          activeId: makeActive ? saved.id : state.activeId,
        )
        .withPhase(saved.id, phase)
        .withError(saved.id, null)
        .withAwaitingPlan(saved.id, awaitingPlan)
        .withOutOfSteps(saved.id, outOfSteps);
  }

  /// Send a turn — implemented by [_ChatSend], called by the queue and the
  /// plan-approval bar.
  ///
  /// [continuing] marks a turn the app is sending on the user's behalf to carry
  /// on work an agent has already started, so it stays with that agent instead
  /// of being routed afresh. See `_ChatSend.send`.
  Future<void> send({
    required NetworkCredential network,
    required String model,
    required String message,
    PlaygroundModality modality,
    List<MediaAttachment> attachments,
    List<ChatFile> files,
    List<ChatContext> contexts,
    bool? planFirst,
    String? into,
    bool continuing,

    /// A slash command the agent runs itself, sent as the whole prompt in place
    /// of one built from the transcript — see [ChatSender.send]. Separate from
    /// [message], which is what the chat shows.
    String? agentCommand,
  });

  /// Hold a turn typed while the chat was busy — [_ChatQueue].
  void _enqueue(String id, QueuedTurn turn);

  /// Put a turn typed mid-answer into the answer itself — [_ChatQueue].
  Future<bool> _steerRunningTurn(String id, QueuedTurn turn);

  /// Send the next held turn, if any — [_ChatQueue].
  bool _drainQueue(String id);

  /// Judge a finished turn against the chat's goal — [_ChatGoals].
  Future<void> _judgeGoalTurn(String id, _TurnOutcome? outcome);

  /// Send the agent back into chat [id] where it ran out of room —
  /// [ChatSessionsController]. Called by the user's "Carry on" and by the
  /// automatic one in [_ChatSettle].
  Future<void> continueChat(String id);

  /// Settle a finished send — [_ChatSettle].
  void _finish(String id);

  /// Act on a reply that talked about a repeat nothing is running, or relayed
  /// an ask the app's own reading missed — [_ChatLoops].
  void _settleLoopClaim(String id);

  /// Run one of the app's own commands — implemented below, declared here so a
  /// mixin can reach it: an ask relayed by a reply runs through exactly the
  /// path the composer uses, rather than a second one that could drift from it.
  Future<CommandOutcome?> runCommand(ChatCommandCall call, {String model = ''});

  /// Whether chat [id] is one the app would carry on by itself as things stand
  /// — [_ChatSettle]. Read by the send that just landed, to keep an
  /// intermediate stop out of the desktop's notifications.
  bool willCarryOn(String id);

  /// Cancel one chat's send — [_ChatSettle].
  void _cancel(String id);

  /// Stop one chat's in-flight reply, keeping any partial and settling it back
  /// to idle — [_ChatSend].
  ///
  /// Two callers, and each is why it is shaped this way. The loop calls it to
  /// abandon a turn that has hung past [kLoopTurnCeiling], so the next iteration
  /// is not blocked behind it. And it is public and **per conversation** because
  /// the Grid Panel interrupts a *project*, which is very often not the chat the
  /// desktop has open — on a desk with a panel on it, nobody is looking at the
  /// window.
  void stopChat(String id);
}

class ChatSessionsController extends _ChatSessions
    with _ChatSend, _ChatSettle, _ChatQueue, _ChatGoals, _ChatLoops {
  /// Whether the user has already chosen what to look at — opened a chat, or
  /// started a new one — before the saved history landed. Once they have,
  /// restoring must not move them somewhere else.
  bool _chose = false;

  /// Chats deleted while the history was still being read, so restoring can't
  /// bring one back from a file listed before it was removed. Null once there's
  /// nothing left to restore.
  Set<String>? _deletedWhileLoading = {};

  Future<void>? _restoring;

  /// Completes when the saved conversations have been read off disk and folded
  /// in. The app never awaits it — the sidebar reads
  /// [ChatSessionsState.loading] instead — but a test seeding a temp dir does,
  /// rather than guessing how many event-loop turns a disk read takes.
  Future<void> get restored => _restoring ?? Future<void>.value();

  @override
  ChatSessionsState build() {
    // Riverpod reuses this *same* notifier across rebuilds, so a flag set by the
    // previous build's teardown is still standing when the next one starts.
    // Left set, `_restore` below reads the folder and then drops what it read on
    // the floor — the history goes empty and stays empty for the rest of the
    // session. Any rebuild triggers it; restoring a cloud backup is what finally
    // found it.
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _cancelAll();
      // A pending loop wake-up would fire into a controller that is gone.
      for (final timer in _loopTimers.values) {
        timer.cancel();
      }
      _loopTimers.clear();
    });
    // Read off the first frame: the whole history is on disk, and decoding it
    // here is the frame's budget spent before anything is drawn (see
    // [ChatStore.loadAll]). The rail shows its loading state until this lands.
    _restoring = _restore();
    // And, racing it, the index — which carries every chat's title and nothing
    // else, so the sidebar fills in about a millisecond instead of waiting out
    // the ~190 ms the transcripts take. Not awaited by [restored]: it is a way
    // to draw sooner, never a step the history depends on.
    unawaited(_previewFromIndex());
    return const ChatSessionsState(loading: true);
  }

  /// Put the saved chats' headers in front of the user while their transcripts
  /// are still being read. See [ChatSessionsState.preview].
  ///
  /// Drops what it read if the full history got there first — the index is the
  /// weaker source of the two, and overwriting the real conversations with
  /// headers would empty every transcript on screen.
  Future<void> _previewFromIndex() async {
    final headers = await _store.loadIndex();
    if (_disposed || headers.isEmpty || !state.loading) return;
    final deleted = _deletedWhileLoading ?? const <String>{};
    state = state.copyWith(
      preview: [
        for (final c in headers)
          if (!deleted.contains(c.id)) c,
      ],
    );
  }

  /// Fold the saved conversations in once they're read.
  ///
  /// Whatever the user did while the disk was read wins: a chat they started is
  /// kept and not duplicated by its own file, one they deleted stays deleted,
  /// and wherever they chose to be is where they stay. Only a user who hasn't
  /// touched anything gets the default — the newest *live* chat, never an
  /// archived one, since landing in a transcript the sidebar doesn't list would
  /// look like the app lost their history.
  Future<void> _restore() async {
    final saved = await _store.loadAll();
    if (_disposed) return;
    final known = {for (final c in state.conversations) c.id};
    final deleted = _deletedWhileLoading ?? const <String>{};
    // Only the chats being folded in are read for an interrupted turn: one
    // already in memory is either mid-turn or newer than its file, and one the
    // user deleted while the disk was being read must not be written back at
    // all — saving a note onto it would put the file, and the chat, back.
    final fresh = _closeInterruptedTurns([
      for (final c in saved)
        if (!known.contains(c.id) && !deleted.contains(c.id)) c,
    ]);
    final merged = [...state.conversations, ...fresh]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _deletedWhileLoading = null;
    final opening = [
      for (final c in merged)
        if (!c.isArchived) c,
    ];
    final settled = _chose || state.activeId != null;
    state = state.copyWith(
      loading: false,
      conversations: merged,
      // The headers have been superseded by the transcripts they stood in for.
      preview: const [],
      activeId: settled
          ? state.activeId
          : (opening.isEmpty ? null : opening.first.id),
    );
    // Last, and only here: the history has to be in state before a loop can be
    // found in it, and this is the one path that reads *this* computer's own
    // chat folder (see [_stopForeignLoop] for the other one).
    _resumeLoops();
    // A loop resumes across a restart; a goal does not. The difference is who
    // the next turn belongs to: a loop sends its own prompt, so nothing of the
    // user's is captured, while a goal takes over whatever they type next — and
    // after a restart that is a sentence they wrote without knowing a goal was
    // still armed (see [GoalStatus.dormant]).
    _standDownGoals();
  }

  /// Close off any turn that the app going away cut short.
  ///
  /// A turn only exists while the app runs, so quitting — or crashing, or a
  /// rebuild during development — mid-turn leaves the user's own message as the
  /// last thing in the chat and no answer to it, ever. Read back as-is that
  /// prompt looks unasked: the next turn, a loop's or the user's, does the whole
  /// task again from nothing. Marking it is what makes the interruption a fact
  /// both readers of the transcript can see (see [kInterruptedTurnNote]).
  ///
  /// Written back to disk as it is marked, so it is done once rather than on
  /// every launch, and so the note is part of the transcript the user scrolls.
  List<Conversation> _closeInterruptedTurns(List<Conversation> saved) {
    final closed = <Conversation>[];
    for (final chat in saved) {
      if (!wasTurnInterrupted(chat)) {
        closed.add(chat);
        continue;
      }
      final marked = markInterruptedTurn(chat);
      _store.save(marked);
      ref
          .read(appLogProvider)
          .info(
            'chat',
            'chat ${chat.id}: the app closed before the last turn answered — '
                'marked it interrupted',
          );
      closed.add(marked);
    }
    return closed;
  }

  /// Re-read the chat folder and fold in whatever changed underneath us.
  ///
  /// For the one case where something other than this controller writes there:
  /// restoring a cloud backup (Settings ▸ Sync & Backup). Rebuilding the whole
  /// provider would also do it, but it tears down every send in flight and
  /// resets what the user is looking at — this keeps both and only swaps the
  /// conversations.
  ///
  /// A chat that is generating right now is left as memory has it: its file is
  /// mid-write, and the copy in hand is the newer one.
  Future<void> reloadFromDisk() async {
    final saved = await _store.loadAll();
    if (_disposed) return;
    final byId = {for (final c in state.conversations) c.id: c};
    for (final c in saved) {
      if (state.sendingFor(c.id)) continue;
      byId[c.id] = _stopForeignLoop(c);
    }
    state = state.copyWith(
      loading: false,
      conversations: byId.values.toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
    );
  }

  /// The project a not-yet-saved chat is being composed in, so the `@`-mention
  /// menu can list that folder before the chat is persisted.
  String? get draftProjectId => state.draftProjectId;

  /// Open a fresh, empty compose, optionally inside [projectId] — the folder the
  /// assistant may read while answering it. Not persisted until the first
  /// message, so clicking "New chat" repeatedly never litters the history with
  /// blanks.
  ///
  /// Allowed while another chat is still streaming: its reply keeps folding into
  /// that chat in the background, and the user gets a clean composer here.
  void newChat({String? projectId}) {
    _chose = true;
    state = state.copyWith(activeId: null, draftProjectId: projectId);
  }

  /// Run a slash command the app owns (see [ChatCommand]).
  ///
  /// Kept on the controller rather than in the view: every one of these acts on
  /// chat state, and a view that reached in and did it itself would be the
  /// second place that knows how.
  ///
  /// Returns the one line to tell the user, or null when the result is its own
  /// confirmation — a new chat opening says "new chat" better than a toast.
  ///
  /// [model] is what the composer is showing: what a chat that `/goal` or
  /// `/loop` has to *start* will answer with. It defaults to none because the
  /// callers with no composer to read — the status line's Stop buttons — only
  /// ever run commands that act on a chat already open.
  /// Runs a command an agent asked for over MCP, in the chat its turn belongs
  /// to, and returns the sentence to hand back as the tool's result.
  ///
  /// **Refuses rather than acting on the wrong conversation.** Every command
  /// here works on the chat that is open ([_startedChat]); a turn answering a
  /// background chat that asked for a loop would otherwise start one wherever
  /// the user happens to be standing, in a conversation nobody connected to the
  /// request. The refusal is written for the agent to repeat, so the user is
  /// told what to type instead of being told nothing.
  Future<String> runAgentAsk(String chatId, ChatCommandCall call) async {
    final chat = _find(chatId);
    if (chat == null) {
      return 'That conversation is no longer here, so nothing was started.';
    }
    if (state.activeId != chatId) {
      return 'Grid runs this in the conversation on screen, and this turn is '
          'answering a different one. Tell the user to type '
          '"/${call.command.name} ${call.argument}" in this chat.';
    }
    final outcome = await runCommand(call, model: chat.model);
    return outcome?.message ?? 'Grid is running /${call.command.name}.';
  }

  @override
  Future<CommandOutcome?> runCommand(
    ChatCommandCall call, {
    String model = '',
  }) async {
    switch (call.command) {
      // Issue #13: a new chat *where the user is standing*. The project comes
      // from the open chat, or from the compose they are already in — dropping
      // it would move them out of the folder they were working in, which is the
      // one thing "start a new chat here" promises not to do.
      case ChatCommand.clear:
        // A goal left running in the chat being left would go on sending turns
        // into a conversation the user has walked away from. Claude Code's
        // `/clear` ends the goal for the same reason.
        final leaving = state.active;
        if (leaving != null) _endLoop(leaving.id);
        if (leaving?.goal != null) {
          _saveAndReplace(_find(leaving!.id)!.copyWith(clearGoal: true));
        }
        newChat(projectId: leaving?.projectId ?? state.draftProjectId);
        return null;
      case ChatCommand.goal:
        final argument = call.argument;
        if (argument.isEmpty) {
          return (
            message: goalStatusLine(state.active?.goal, DateTime.now()),
            failed: false,
          );
        }
        if (kGoalClearWords.contains(argument.toLowerCase())) {
          return _clearGoal();
        }
        return _setGoal(argument, model);
      case ChatCommand.loop:
        final argument = call.argument;
        if (kGoalClearWords.contains(argument.toLowerCase())) {
          return _stopLoop();
        }
        return _startLoop(argument, model);
      case ChatCommand.schedule:
        return _scheduleTask(call.argument, model);
      case ChatCommand.compact:
        return _compact(call.argument);
    }
  }

  /// Save what [argument] describes as a task on the machine's own scheduler,
  /// answering back into this chat.
  ///
  /// Delivery is not a question worth asking: the user set it up *here*, in a
  /// sentence, so here is where they will look for the answer — and the runner
  /// is the assistant they were talking to when they asked, for the same
  /// reason. The Scheduled screen is where either can be changed afterwards.
  Future<CommandOutcome?> _scheduleTask(String argument, String model) async {
    // What it says has to be readable *before* a chat is started for it, or a
    // typo leaves an empty conversation in the sidebar — the same order `/loop`
    // checks in, and for the same reason.
    final request = parseScheduleArgument(argument);
    if (request == null) {
      return (message: kScheduleUsage, failed: true);
    }
    // On a blank composer this starts the chat it will answer into, rather than
    // refusing: "/schedule" on launch is an ordinary thing to do, and the chat
    // is the destination, not a precondition.
    final chat = _startedChat(model);
    final runner = taskRunnerFor(ref.read(activeChatAgentProvider));
    final result = await ref
        .read(scheduledJobsProvider.notifier)
        .create(
          name: clipChatTitle(request.prompt),
          prompt: request.prompt,
          schedule: request.schedule,
          model: model.isEmpty ? chat.model : model,
          runner: runner,
          destination: TaskChatDestination(chat.id),
          workdir: ref.read(projectByIdProvider(chat.projectId))?.path,
          projectId: chat.projectId,
        );
    if (result.error != null) return (message: result.error!, failed: true);
    return (
      message:
          '${request.schedule.describe()}: ${request.prompt}. '
          'Answers here, and keeps running with Grid closed.',
      failed: false,
    );
  }

  /// How long the summarizer gets. Long, because it is reading a whole
  /// conversation and the user asked for this and is waiting on it — unlike the
  /// router's 8s, which runs in front of a turn nobody asked to delay.
  static const _compactTimeout = Duration(seconds: 90);

  /// Fold the open chat's history into a summary the next turn carries in its
  /// place (see [ChatCompaction]).
  Future<CommandOutcome?> _compact(String focus) async {
    final chat = state.active;
    if (chat == null || chat.messages.isEmpty) {
      return (
        message: "There's nothing to compact yet — this chat is empty.",
        failed: true,
      );
    }
    if ((chat.compaction?.through ?? 0) >= chat.messages.length) {
      return (
        message: 'Already compacted — nothing new has been said since.',
        failed: false,
      );
    }
    final target = resolveOneShotTarget(ref);
    if (target == null) {
      return (
        message:
            "No model is available to write the summary. Start an engine or "
            "pick a grid that serves one, then try again.",
        failed: true,
      );
    }

    final id = chat.id;
    // The transcript as the *assistant* sees it, so a second compaction folds
    // in the first summary instead of dropping everything it stood for.
    final seen = historyForTurn(chat.messages, chat.compaction);
    final covered = chat.messages.length;
    final log = ref.read(appLogProvider);
    final (reply, error) = await ref
        .read(chatTransportProvider)
        .complete(
          endpoint: target.endpoint,
          apiKey: target.apiKey,
          model: target.model,
          messages: buildCompactMessages(messages: seen, focus: focus),
        )
        .timeout(
          _compactTimeout,
          onTimeout: () =>
              (null, const ChatTransportError('summarizing timed out')),
        );

    if (_disposed) return null;
    final summary = reply?.trim() ?? '';
    if (error != null || summary.isEmpty) {
      // The sentence the user reads is not the record: log what actually came
      // back, or the next person debugging this has only the apology (§6).
      log.warn(
        'chat',
        'compacting $id failed: ${error?.message ?? 'the model replied with '
                'nothing'}',
      );
      return (
        message: error == null
            ? "The model returned an empty summary, so nothing was compacted."
            : friendlyOneShotError(error, what: 'summarize this chat'),
        failed: true,
      );
    }

    // Re-read: the chat may have been deleted, or answered again, while the
    // summary was being written. [covered] is the length as it was when we
    // asked, so a message that landed since stays outside the summary.
    final current = _find(id);
    if (current == null) return null;
    _saveAndReplace(
      current.copyWith(
        compaction: ChatCompaction(
          summary: summary,
          through: covered,
          at: DateTime.now(),
        ),
        clearResume: true,
      ),
    );
    log.info('chat', 'compacted $id through $covered messages');
    return (
      message:
          'Context compacted. The chat is all still here — the assistant now '
          'carries a summary of it.',
      failed: false,
    );
  }

  /// Switch to a saved conversation. Allowed mid-send — a reply streaming into
  /// another chat keeps going in the background and the switch never lands it in
  /// the wrong transcript, because each send folds into its own conversation id.
  void select(String id) {
    if (id == state.activeId) return;
    _chose = true;
    // The ordinary case, and synchronous as it has always been: the chat is in
    // hand, so opening it is one assignment.
    if (state.conversations.any((c) => c.id == id)) {
      state = state.copyWith(activeId: id);
      return;
    }
    unawaited(_openUnread(id));
  }

  /// Open a chat the sidebar drew from the index, whose transcript hasn't been
  /// read yet — the one window where that can happen is the moment or two
  /// between the rail filling in and the history landing.
  ///
  /// The switch waits for the file rather than happening first, because the
  /// alternative is the user standing in a chat the app believes is empty: the
  /// composer would let them speak into it, and the send would save that one
  /// message *over* the transcript. A single file is a few milliseconds; losing
  /// a conversation is forever.
  Future<void> _openUnread(String id) async {
    final loaded = await _store.load(id);
    if (_disposed) return;
    final gone = _deletedWhileLoading?.contains(id) ?? false;
    // Not `else`: the full history can have landed while this file was read, in
    // which case the chat is already in hand and this copy is the older one.
    final known = state.conversations.any((c) => c.id == id);
    final merged = loaded == null || gone || known
        ? state.conversations
        : ([
            ...state.conversations,
            ..._closeInterruptedTurns([loaded]),
          ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)));
    // The id is set even when nothing was read: a click that visibly does
    // nothing is worse than a chat that fills in when the history lands.
    state = state.copyWith(conversations: merged, activeId: gone ? null : id);
  }

  /// Remember the model chosen for the open conversation, so leaving the chat and
  /// coming back — or reopening it later — restores *that* choice, not the grid's
  /// default. A no-op for a not-yet-saved compose (its model rides the first
  /// send) and while *this* chat's reply is streaming. Leaves `updatedAt`
  /// untouched, so picking a model never re-sorts the sidebar.
  void setActiveModel(String model) {
    if (state.sending || model.isEmpty) return;
    final active = state.active;
    if (active == null || active.model == model) return;
    final updated = active.copyWith(model: model);
    _saveAndReplace(updated);
  }

  /// Set how much the assistant may do without asking.
  ///
  /// Which of the two things this writes depends on where the user is standing,
  /// and the split is the point of the feature:
  ///
  /// - In an open chat it changes **that chat only**. Granting full access to
  ///   get one job done no longer leaves every other conversation — including
  ///   tomorrow's, about something else — running without asking.
  /// - On a blank composer there is no chat yet, so it sets the app's standing
  ///   choice: the mode every chat that has never been told follows, and the
  ///   one the chat about to be started will run under.
  ///
  /// Leaves `updatedAt` alone, like [setActiveModel]: changing what a chat may
  /// do is not talking in it, and must not re-sort the sidebar.
  void setApproval(AgentApprovalMode approval) {
    final active = state.active;
    if (active == null) {
      ref.read(chatPrefsProvider.notifier).setApproval(approval);
      return;
    }
    if (active.approval == approval) return;
    final updated = active.copyWith(approval: approval);
    _saveAndReplace(updated);
  }

  /// Pin [id] to the top of the sidebar, or let it back into the ordinary order.
  ///
  /// Leaves `updatedAt` alone for the usual reason: pinning a chat is not
  /// talking in it, and it must not jump the chat's position *within* its group
  /// as a side effect of being pinned.
  void togglePinned(String id) {
    final chat = _find(id);
    if (chat == null) return;
    final pinned = chat.copyWith(pinned: !chat.pinned);
    _saveAndReplace(pinned);
  }

  /// Give a conversation the name the user typed, replacing whatever was
  /// derived from its first message.
  ///
  /// [updatedAt] is deliberately left alone: it orders the sidebar by when a
  /// chat was last *talked in*, and retitling one is not talking in it — bumping
  /// it would jump an old chat to the top for a cosmetic edit.
  void renameConversation(String id, String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    final chat = _find(id);
    if (chat == null || chat.title == trimmed) return;
    // Locked from here on: the agent's own name for this chat can still be
    // seconds out, and it must not overwrite the one the user just typed.
    final renamed = chat.copyWith(title: trimmed, titleLocked: true);
    _saveAndReplace(renamed);
  }

  /// Delete a conversation from disk and state, falling back to the newest
  /// remaining one (or a new compose) when the open one is removed. A reply
  /// streaming into it is cancelled first, so nothing writes back afterwards.
  void deleteConversation(String id) {
    _cancel(id);
    // Nothing may go on repeating into a chat that no longer exists.
    _cancelLoopTimer(id);
    _store.delete(id);
    _deletedWhileLoading?.add(id);
    // The chat that held this undo is gone, so nothing can reach it any more —
    // drop the snapshots rather than keep whole file contents in memory for a
    // conversation the user deleted, and its live feed with them.
    ref.read(agentChangesProvider.notifier).forget(id);
    ref.read(agentRunsProvider.notifier).forget(id);
    ref.read(agentQuestionsProvider.notifier).clear(id);
    final remaining = [
      for (final c in state.conversations)
        if (c.id != id) c,
    ];
    final activeId = state.activeId == id
        ? (remaining.isEmpty ? null : remaining.first.id)
        : state.activeId;
    state = state
        .withoutInFlight({id})
        .copyWith(conversations: remaining, activeId: activeId);
  }

  /// Archive a conversation: hide it from the sidebar, the tray and ⌘K without
  /// touching a single message in it. The transcript stays on disk and comes
  /// back whole from [unarchiveConversation].
  ///
  /// Ignored while a reply is streaming into it: filing away a chat mid-reply
  /// would leave that reply landing in a transcript the user can no longer see.
  void archiveConversation(String id) {
    if (state.sendingFor(id)) return;
    final chat = _find(id);
    if (chat == null || chat.isArchived) return;
    final archived = chat.copyWith(archivedAt: DateTime.now());
    _store.save(archived);
    _replace(archived, activeId: _activeIdAfterHiding(id));
  }

  /// Put an archived conversation back: it returns to the sidebar in its old
  /// place (ordered by [Conversation.updatedAt] — archiving never touched it,
  /// so it lands back where the user last left it, not at the top).
  void unarchiveConversation(String id) {
    final chat = _find(id);
    if (chat == null || !chat.isArchived) return;
    final restored = chat.copyWith(clearArchivedAt: true);
    _store.save(restored);
    _replace(restored, activeId: state.activeId);
  }

  /// Delete every archived conversation — the Archived screen's "Delete all".
  /// Live chats are left strictly alone, so the button can never reach the
  /// history the user is still working in.
  ///
  /// Takes an optional [ids] subset for "Delete all in project", which is the
  /// same operation scoped to one group.
  void deleteArchivedConversations({Set<String>? ids}) {
    final doomed = [
      for (final c in state.conversations)
        if (c.isArchived && (ids == null || ids.contains(c.id))) c.id,
    ];
    if (doomed.isEmpty) return;
    final changes = ref.read(agentChangesProvider.notifier);
    final runs = ref.read(agentRunsProvider.notifier);
    final questions = ref.read(agentQuestionsProvider.notifier);
    for (final id in doomed) {
      _cancel(id);
      _store.delete(id);
      changes.forget(id);
      runs.forget(id);
      questions.clear(id);
      _deletedWhileLoading?.add(id);
    }
    final gone = doomed.toSet();
    final remaining = [
      for (final c in state.conversations)
        if (!gone.contains(c.id)) c,
    ];
    // The open chat is normally live (archived ones aren't reachable from the
    // sidebar), but it *can* be the one just deleted — the user can open an
    // archived chat from the Archived screen. Fall back like delete does.
    final activeId = gone.contains(state.activeId)
        ? (remaining.isEmpty ? null : remaining.first.id)
        : state.activeId;
    state = state
        .withoutInFlight(gone)
        .copyWith(conversations: remaining, activeId: activeId);
  }

  /// Where to send the user when the chat with [id] stops being visible: stay
  /// put unless it was the open one, in which case fall back to the newest chat
  /// still in the sidebar (or a fresh compose when none is left).
  String? _activeIdAfterHiding(String id) {
    if (state.activeId != id) return state.activeId;
    for (final c in state.conversations) {
      if (c.id != id && !c.isArchived) return c.id;
    }
    return null;
  }

  /// Put work the assistant did on its own into the chat: the result of a
  /// scheduled task, delivered into the conversation with id [id] (created,
  /// named [title], the first time that task produces anything).
  ///
  /// It arrives like any other message the assistant sent — but it must never
  /// take over: whatever chat is open stays open, and a reply in flight is left
  /// alone. The task's chat simply appears in the sidebar (newest first, like
  /// every other), for the user to read when they want to.
  void deliverFromAgent({
    required String id,
    required String title,
    required String text,
    required DateTime at,
    String? projectId,
  }) {
    if (text.trim().isEmpty) return;

    final existing = _find(id);
    final message = ChatMessage(role: ChatRole.assistant, text: text.trim());
    final conversation =
        (existing ??
                Conversation(
                  id: id,
                  title: title,
                  model: '',
                  createdAt: at,
                  updatedAt: at,
                  // A scheduled task's chat is born inside its project (when it
                  // has one), so it appears under that project's rail from the
                  // first result rather than sitting loose until reconciled.
                  projectId: projectId,
                ))
            .copyWith(
              updatedAt: at,
              messages: [...?existing?.messages, message],
              // Backfills the project on a chat created before the link existed;
              // a null projectId keeps whatever it already had.
              projectId: projectId,
            );

    _store.save(conversation);
    state = state.copyWith(
      conversations: [
        if (existing == null) conversation,
        for (final c in state.conversations)
          if (c.id == id) conversation else c,
      ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
    );
  }

  /// Put an already-saved chat under [projectId] when it isn't there yet — used
  /// to reconcile a scheduled task's chat that was created before the app linked
  /// the task to a project, without waiting on the next run to deliver.
  ///
  /// A no-op when the chat is missing or already carries that project, so it's
  /// cheap to call on every sweep. Leaves `updatedAt` untouched: re-homing a
  /// chat isn't talking in it, and must not jump it to the top of the sidebar.
  void linkToProject(String id, String projectId) {
    final existing = _find(id);
    if (existing == null || existing.projectId == projectId) return;
    final linked = existing.copyWith(projectId: projectId);
    _saveAndReplace(linked);
  }

  /// Make [id] the conversation for the document at [path] — Docs pairs one
  /// chat with one file, and this is where that pairing is written down.
  ///
  /// A no-op when the chat is missing or already carries a document, because
  /// the pairing is made once: a chat that belongs to a file goes on belonging
  /// to it (see [Conversation.documentPath]). Leaves `updatedAt` alone for the
  /// reason [linkToProject] does — pairing a chat isn't talking in it.
  void linkToDocument(String id, String path) {
    final existing = _find(id);
    if (existing == null || existing.documentPath != null) return;
    _saveAndReplace(existing.copyWith(documentPath: path));
  }

  /// Approve the plan the agent just proposed: carry it out. The execute turn
  /// continues the same session (so the agent already has the plan in context)
  /// with the planning flag off, so it runs asking per action rather than
  /// planning again. A no-op unless a plan is actually waiting on the open chat.
  Future<void> approvePlan() {
    if (!state.awaitingPlan || state.sending) return Future.value();
    final network = ref.read(selectedNetworkProvider);
    final active = state.active;
    if (network == null || active == null) return Future.value();
    return send(
      network: network,
      model: active.model,
      message: 'The plan looks good — go ahead and carry it out.',
      planFirst: false,
      // The agent that wrote the plan is the only one that has it.
      continuing: true,
    );
  }

  /// The user answered the assistant's questions from the card over the
  /// composer.
  ///
  /// An ordinary message, because that is all it can be: the `AskUserQuestion`
  /// call that asked was answered by the CLI itself the moment it was made (see
  /// [ClaudeQuestionsEvent]), so there is no request left to reply to — only the
  /// next thing to say. [continuing] keeps it with the agent that asked, and the
  /// card is cleared first so a queued answer doesn't leave the question sitting
  /// there as though nobody had answered it.
  Future<void> answerQuestions(String message) {
    final network = ref.read(selectedNetworkProvider);
    final active = state.active;
    if (network == null || active == null || message.trim().isEmpty) {
      return Future.value();
    }
    ref.read(agentQuestionsProvider.notifier).clear(active.id);
    return send(
      network: network,
      model: active.model,
      message: message,
      continuing: true,
    );
  }

  /// The user pressing "Carry on" on the open chat.
  ///
  /// Also hands that chat a fresh carry-on budget: the app stops on its own
  /// after [kCarryOnTurns] turns, and a user who has read where it got to and
  /// asked for more has answered exactly the question that stop was asking.
  Future<void> continueTurn() {
    final id = state.activeId;
    if (id == null) return Future.value();
    state = state.withCarriedOn(id, 0);
    return continueChat(id);
  }

  /// Send the agent back into chat [id] where it ran out of room.
  ///
  /// The assistant didn't stop because it was finished — it used every tool call
  /// one turn is allowed and Hermes made it summarise. Carrying on is a fresh
  /// turn with a fresh budget, and the agent keeps the conversation, so the
  /// message only has to point it at the work it named itself.
  ///
  /// By id rather than "the open chat", because the app sends this itself when a
  /// turn runs out of room (see `_ChatSettle`) — and the chat that ran out may be
  /// one the user has since switched away from.
  @override
  Future<void> continueChat(String id) {
    if (!state.outOfStepsFor(id) || state.sendingFor(id)) {
      return Future.value();
    }
    final network = ref.read(selectedNetworkProvider);
    final chat = _find(id);
    if (network == null || chat == null) return Future.value();
    return send(
      network: network,
      model: chat.model,
      message: 'Carry on from where you stopped — finish the steps still open.',
      into: id,
      // "Where you stopped" only means something to the agent that stopped.
      continuing: true,
    );
  }

  /// Wave away the "carry on" bar without sending anything — the work stopping
  /// short may be fine, and the user may simply want to say something else.
  void dismissOutOfSteps() {
    final id = state.activeId;
    if (id == null || !state.outOfStepsFor(id)) return;
    state = state.withOutOfSteps(id, false);
  }

  /// Dismiss the proposed plan without running it — the plan stays in the
  /// transcript, but the "approve & run" bar goes away and the user can just
  /// carry on chatting.
  void dismissPlan() {
    final id = state.activeId;
    if (id == null || !state.awaitingPlanFor(id)) return;
    state = state.withAwaitingPlan(id, false);
  }

  /// Drop the open chat's last-turn failure.
  ///
  /// For when the thing the message described stops being true — handing the
  /// chat to a different agent, say. Left up, the sentence keeps blaming an
  /// agent that is no longer answering, above a button offering to switch back
  /// to it.
  void clearError() {
    final id = state.activeId;
    if (id == null || state.errorFor(id) == null) return;
    _retryableTurns.remove(id);
    state = state.withError(id, null);
  }
}
