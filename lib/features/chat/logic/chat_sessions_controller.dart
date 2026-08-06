import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/text_preview.dart';
import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/platform/desktop_notifier.dart';
import '../../../infrastructure/platform/window_focus.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../agents/logic/agent_changes.dart';
import '../../agents/logic/agent_routing.dart';
import '../../agents/logic/agent_session_title.dart';
import '../../agents/logic/active_chat_agent.dart';
import '../../agents/logic/agent_status.dart';
import '../../auth/logic/session_controller.dart';
import '../../playground/logic/chat_message.dart';
import '../../playground/logic/chat_sender.dart';
import '../../playground/logic/media_outputs.dart';
import '../../playground/logic/playground_request.dart';
import '../../projects/logic/project.dart';
import 'chat_approval.dart';
import 'chat_goal.dart';
import 'chat_sessions_state.dart';
import 'chat_store.dart';
import 'conversation.dart';

/// Re-exported so every file that already imports the controller keeps seeing
/// [ChatSessionsState] — moving the state out is not a change any caller has to
/// hear about.
export 'chat_sessions_state.dart';

part 'chat_sessions_goals.dart';
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

/// The plumbing the Chat tab's four jobs share — running a turn, settling it,
/// holding what the user typed behind it, and driving a goal.
///
/// They live in files of their own (§4) and reach the same state through this
/// spine. What is left `abstract` below is exactly the set of calls those four
/// make into each other: naming them in one place is what keeps the seams
/// visible instead of hiding a cycle inside one 1,400-line class.
abstract class _ChatSessions extends Notifier<ChatSessionsState> {
  /// One live subscription per streaming conversation, so [stop] and disposal
  /// tear down exactly the one they mean and each reply folds into its own chat.
  final Map<String, StreamSubscription<ChatSendUpdate>> _subs = {};
  final Map<String, Completer<void>> _dones = {};

  /// Naming a chat outlives the send it started in (the agent writes the name
  /// seconds later), so it has to know when there's no longer a state to write.
  bool _disposed = false;

  /// How the last turn of each chat ended, so [_finish] can move that chat's
  /// goal on without the update stream having to carry it there. Written as the
  /// turn lands, read and dropped as it settles; absent means the turn was
  /// stopped rather than finished.
  final Map<String, ({String? reply, String? failure})> _lastTurn = {};

  /// Agent turns waiting for the slot, oldest first. The chat holding the slot
  /// is [ChatSessionsState.runningAgentId]; the local agent has one live session
  /// and one permission focus, so agent turns are serialized — a second waits
  /// here rather than clobbering the first (two at once left one chat hung on a
  /// permission the other had cleared). The user turn is already committed and
  /// the chat sits in [SendBusy] until its [dispatch] runs. Relay/media turns
  /// touch none of this and never queue.
  final List<({String id, void Function() dispatch})> _agentQueue = [];

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
  /// picking a model, setting a goal: write it, swap it in, leave `updatedAt`
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
        .withAwaitingPlan(saved.id, awaitingPlan);
  }

  /// Send a turn — implemented by [_ChatSend], called by the queue, the goal
  /// loop and the plan-approval bar.
  Future<void> send({
    required NetworkCredential network,
    required String model,
    required String message,
    PlaygroundModality modality,
    List<MediaAttachment> attachments,
    List<ChatFile> files,
    bool? planFirst,
    String? into,
  });

  /// Hold a turn typed while the chat was busy — [_ChatQueue].
  void _enqueue(QueuedTurn turn);

  /// Send the next held turn, if any — [_ChatQueue].
  bool _drainQueue(String id);

  /// Move a goal on now that a turn has ended — [_ChatGoals].
  void _advanceGoal(String id, ({String? reply, String? failure})? outcome);

  /// Settle a finished send — [_ChatSettle].
  void _finish(String id);

  /// Cancel one chat's send — [_ChatSettle].
  void _cancel(String id);
}

class ChatSessionsController extends _ChatSessions
    with _ChatSend, _ChatSettle, _ChatQueue, _ChatGoals {
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
    ref.onDispose(() {
      _disposed = true;
      _cancelAll();
    });
    // Read off the first frame: the whole history is on disk, and decoding it
    // here is the frame's budget spent before anything is drawn (see
    // [ChatStore.loadAll]). The rail shows its loading state until this lands.
    _restoring = _restore();
    return const ChatSessionsState(loading: true);
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
    final merged = [
      ...state.conversations,
      for (final c in saved)
        if (!known.contains(c.id) && !deleted.contains(c.id)) c,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _deletedWhileLoading = null;
    final opening = [
      for (final c in merged)
        if (!c.isArchived) c,
    ];
    final settled = _chose || state.activeId != null;
    state = state.copyWith(
      loading: false,
      conversations: merged,
      activeId: settled
          ? state.activeId
          : (opening.isEmpty ? null : opening.first.id),
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

  /// Switch to a saved conversation. Allowed mid-send — a reply streaming into
  /// another chat keeps going in the background and the switch never lands it in
  /// the wrong transcript, because each send folds into its own conversation id.
  void select(String id) {
    if (id == state.activeId) return;
    _chose = true;
    state = state.copyWith(activeId: id);
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
    _store.delete(id);
    _deletedWhileLoading?.add(id);
    // The chat that held this undo is gone, so nothing can reach it any more —
    // drop the snapshots rather than keep whole file contents in memory for a
    // conversation the user deleted.
    ref.read(agentChangesProvider.notifier).forget(id);
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
    for (final id in doomed) {
      _cancel(id);
      _store.delete(id);
      changes.forget(id);
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
    );
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
    state = state.withError(id, null);
  }
}
