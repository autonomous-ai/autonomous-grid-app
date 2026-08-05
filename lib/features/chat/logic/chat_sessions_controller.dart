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
import 'chat_store.dart';
import 'conversation.dart';

export '../../playground/logic/chat_message.dart'
    show
        ChatRole,
        ChatMessage,
        ChatMedia,
        SendPhase,
        SendBusy,
        SendGenerating,
        SendStreaming;

/// Sentinel for [ChatSessionsState.copyWith] so `activeId: null` can clear the
/// open chat (compose a new one) while omitting it keeps the current one.
const Object _keep = Object();

/// A message the user typed while the chat was still answering the last one.
///
/// The composer used to simply drop it: [ChatSessionsController.send] returned
/// early while a reply was in flight, so a follow-up thought had to be held in
/// the user's head until the agent finished — which, for an agent turn, can be
/// minutes. Everything the send needs is carried here so the queued turn goes
/// out exactly as it would have, on the grid and model that were chosen at the
/// time rather than whatever is selected when it finally runs.
class QueuedTurn {
  const QueuedTurn({
    required this.network,
    required this.model,
    required this.text,
    required this.modality,
    required this.attachments,
  });

  final NetworkCredential network;
  final String model;
  final String text;
  final PlaygroundModality modality;
  final List<MediaAttachment> attachments;
}

/// The Chat tab's whole state: every saved conversation (newest first), which
/// one is open, and the in-flight send state **per conversation**, so a reply
/// can stream in one chat while the user starts or reads another. A null
/// [activeId] means the user is composing a brand-new chat that isn't saved yet
/// — it gets persisted the moment they send the first message.
///
/// [phases], [errors] and [awaitingPlanIds] are keyed by conversation id and
/// hold only the chats that have something in flight; a chat that is idle simply
/// isn't in them. The plain [phase]/[error]/[sending]/[awaitingPlan] getters
/// report the **open** conversation's state — what the composer and transcript
/// on screen react to — while [phaseFor]/[sendingFor] answer for any chat, so
/// the sidebar can mark a background chat that is still working.
class ChatSessionsState {
  const ChatSessionsState({
    this.conversations = const [],
    this.activeId,
    this.draftProjectId,
    this.phases = const {},
    this.errors = const {},
    this.awaitingPlanIds = const {},
    this.runningAgentId,
    this.queued = const {},
    this.loading = false,
  });

  final List<Conversation> conversations;
  final String? activeId;

  /// True until the saved history has been read off disk. [conversations] is
  /// empty meanwhile, which is not the same fact as "this user has no chats" —
  /// anything that would tell them so must wait for this to clear.
  final bool loading;

  /// The project a not-yet-saved chat is being composed in, or null. A new chat
  /// isn't persisted until its first message, so [active] is null while it's
  /// composed — this holds the project so the pane can still show its rail (and
  /// the `@`-mention menu its folder) before the first send saves it.
  final String? draftProjectId;

  /// The conversation whose **agent** turn is running right now, or null. Agent
  /// turns are serialized onto one live session and one shared activity/
  /// permission feed, so exactly one chat owns that feed at a time — the UI reads
  /// this to show the "agent is working" steps on that chat and a plain "waiting"
  /// cue on any other agent chat still queued behind it.
  final String? runningAgentId;

  /// In-flight send phase per conversation id — absent means idle.
  final Map<String, SendPhase> phases;

  /// The last turn's error per conversation id — absent/null means none.
  final Map<String, String?> errors;

  /// What the user typed while a chat was still answering, per conversation id,
  /// oldest first — sent one at a time as the chat frees up.
  ///
  /// Live state, not saved with the conversation: a queued follow-up is a
  /// message that hasn't been sent, and quitting the app is as clear a "don't
  /// send it" as pressing cancel.
  final Map<String, List<QueuedTurn>> queued;

  /// Conversations whose last turn was Plan mode's planning turn and whose plan
  /// is waiting on the user: the chat shows an "approve & run" bar. Cleared the
  /// moment anything else happens in that chat (a new send, approving,
  /// dismissing) — it's live interaction state, not saved with the conversation.
  final Set<String> awaitingPlanIds;

  /// The open conversation, or null while composing a new one.
  Conversation? get active {
    final id = activeId;
    if (id == null) return null;
    for (final c in conversations) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// The project the chat on screen belongs to — a saved chat's own project, or
  /// the [draftProjectId] while a new one is still being composed. Null for a
  /// plain chat outside any project.
  String? get openProjectId =>
      activeId == null ? draftProjectId : active?.projectId;

  /// The chats that haven't been archived — what the sidebar, the tray menu and
  /// ⌘K all list. [conversations] stays the whole set so the Archived screen
  /// has something to read; anything showing the user their *working* history
  /// wants this instead.
  List<Conversation> get live => liveConversations(conversations);

  /// The archived chats, most recently archived first — the Archived screen's
  /// source list, before its own search/sort/filter narrow it further.
  List<Conversation> get archived => [
    for (final c in conversations)
      if (c.isArchived) c,
  ]..sort((a, b) => b.archivedAt!.compareTo(a.archivedAt!));

  /// The send phase of the chat with [id] (idle when it has nothing in flight).
  SendPhase phaseFor(String? id) =>
      (id == null ? null : phases[id]) ?? const SendIdle();

  /// Whether the chat with [id] has a reply in flight.
  bool sendingFor(String? id) => phaseFor(id) is! SendIdle;

  /// The last error on the chat with [id], or null.
  String? errorFor(String? id) => id == null ? null : errors[id];

  /// Whether the chat with [id] has a plan waiting on approval.
  bool awaitingPlanFor(String? id) =>
      id != null && awaitingPlanIds.contains(id);

  /// What is waiting to be sent in the chat with [id], oldest first.
  List<QueuedTurn> queuedFor(String? id) =>
      (id == null ? null : queued[id]) ?? const [];

  /// What is waiting to be sent in the **open** chat — what the composer shows
  /// above itself, so a queued follow-up is visible rather than only remembered.
  List<QueuedTurn> get queuedHere => queuedFor(activeId);

  /// The open conversation's send phase — what the on-screen transcript shows.
  SendPhase get phase => phaseFor(activeId);

  /// True while the **open** conversation has a request in flight — the composer
  /// disables on this. A reply streaming in a chat the user has switched away
  /// from leaves this false, so that other chat's composer stays usable.
  bool get sending => sendingFor(activeId);

  /// The open conversation's last error.
  String? get error => errorFor(activeId);

  /// Whether the open conversation has a plan waiting on approval.
  bool get awaitingPlan => awaitingPlanFor(activeId);

  ChatSessionsState copyWith({
    List<Conversation>? conversations,
    Object? activeId = _keep,
    Object? draftProjectId = _keep,
    Map<String, SendPhase>? phases,
    Map<String, String?>? errors,
    Set<String>? awaitingPlanIds,
    Object? runningAgentId = _keep,
    Map<String, List<QueuedTurn>>? queued,
    bool? loading,
  }) => ChatSessionsState(
    loading: loading ?? this.loading,
    conversations: conversations ?? this.conversations,
    activeId: identical(activeId, _keep) ? this.activeId : activeId as String?,
    draftProjectId: identical(draftProjectId, _keep)
        ? this.draftProjectId
        : draftProjectId as String?,
    phases: phases ?? this.phases,
    errors: errors ?? this.errors,
    awaitingPlanIds: awaitingPlanIds ?? this.awaitingPlanIds,
    runningAgentId: identical(runningAgentId, _keep)
        ? this.runningAgentId
        : runningAgentId as String?,
    queued: queued ?? this.queued,
  );

  /// This state with [turns] waiting in the chat [id] — dropped from the map
  /// when there's nothing left, so [queued] only holds chats with a backlog.
  ChatSessionsState withQueue(String id, List<QueuedTurn> turns) {
    final next = Map<String, List<QueuedTurn>>.from(queued);
    if (turns.isEmpty) {
      next.remove(id);
    } else {
      next[id] = List.unmodifiable(turns);
    }
    return copyWith(queued: Map.unmodifiable(next));
  }

  /// This state with the chat [id]'s phase set — removed from the map when it
  /// goes idle, so [phases] only ever holds the chats actually working.
  ChatSessionsState withPhase(String id, SendPhase phase) {
    final next = Map<String, SendPhase>.from(phases);
    if (phase is SendIdle) {
      next.remove(id);
    } else {
      next[id] = phase;
    }
    return copyWith(phases: next);
  }

  /// This state with the chat [id]'s error set (or cleared when null).
  ChatSessionsState withError(String id, String? error) {
    final next = Map<String, String?>.from(errors);
    if (error == null) {
      next.remove(id);
    } else {
      next[id] = error;
    }
    return copyWith(errors: next);
  }

  /// This state with the chat [id]'s plan-waiting flag set or cleared.
  ChatSessionsState withAwaitingPlan(String id, bool awaiting) {
    final next = Set<String>.from(awaitingPlanIds);
    if (awaiting) {
      next.add(id);
    } else {
      next.remove(id);
    }
    return copyWith(awaitingPlanIds: next);
  }

  /// Drop every trace of the chats in [ids] — their in-flight phase, error and
  /// plan flag — for when they're deleted.
  ChatSessionsState withoutInFlight(Set<String> ids) => copyWith(
    phases: {
      for (final e in phases.entries)
        if (!ids.contains(e.key)) e.key: e.value,
    },
    errors: {
      for (final e in errors.entries)
        if (!ids.contains(e.key)) e.key: e.value,
    },
    awaitingPlanIds: {
      for (final id in awaitingPlanIds)
        if (!ids.contains(id)) id,
    },
  );
}

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

class ChatSessionsController extends Notifier<ChatSessionsState> {
  /// One live subscription per streaming conversation, so [stop] and disposal
  /// tear down exactly the one they mean and each reply folds into its own chat.
  final Map<String, StreamSubscription<ChatSendUpdate>> _subs = {};
  final Map<String, Completer<void>> _dones = {};

  /// Naming a chat outlives the send it started in (the agent writes the name
  /// seconds later), so it has to know when there's no longer a state to write.
  bool _disposed = false;

  /// Agent turns waiting for the slot, oldest first. The chat holding the slot
  /// is [ChatSessionsState.runningAgentId]; the local agent has one live session
  /// and one permission focus, so agent turns are serialized — a second waits
  /// here rather than clobbering the first (two at once left one chat hung on a
  /// permission the other had cleared). The user turn is already committed and
  /// the chat sits in [SendBusy] until its [dispatch] runs. Relay/media turns
  /// touch none of this and never queue.
  final List<({String id, void Function() dispatch})> _agentQueue = [];

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

  ChatStore get _store => ref.read(chatStoreProvider);

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
    _store.save(updated);
    state = state.copyWith(
      conversations: [
        for (final c in state.conversations)
          if (c.id == updated.id) updated else c,
      ],
    );
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
    _store.save(updated);
    state = state.copyWith(
      conversations: [
        for (final c in state.conversations)
          if (c.id == updated.id) updated else c,
      ],
    );
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
    _store.save(renamed);
    state = state.copyWith(
      conversations: [
        for (final c in state.conversations)
          if (c.id == renamed.id) renamed else c,
      ],
    );
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
    _store.save(linked);
    state = state.copyWith(
      conversations: [
        for (final c in state.conversations)
          if (c.id == id) linked else c,
      ],
    );
  }

  /// Send [message] in the open chat — or, when [into] names one, in that chat
  /// without bringing it to the front (how a queued follow-up goes out).
  ///
  /// Typing while the open chat is still answering **queues** the message rather
  /// than dropping it: an agent turn can run for minutes, and the follow-up
  /// thought shouldn't have to be held in the user's head until it ends. The
  /// queue drains one turn at a time as the chat frees up (see [_drainQueue]).
  Future<void> send({
    required NetworkCredential network,
    required String model,
    required String message,
    PlaygroundModality modality = PlaygroundModality.text,
    List<MediaAttachment> attachments = const [],
    bool? planFirst,
    String? into,
  }) async {
    final text = message.trim();
    if (text.isEmpty) return;

    if (into == null && state.sending) {
      _enqueue(
        QueuedTurn(
          network: network,
          model: model,
          text: text,
          modality: modality,
          attachments: List.unmodifiable(attachments),
        ),
      );
      return;
    }

    // The chat this turn lands in. A queued follow-up names it, because by the
    // time it goes out the user may well be reading something else — and it
    // must go where it was typed, not wherever they have moved to.
    final target = into == null ? _activeOrNew(model) : _find(into);
    // The chat was deleted while its follow-up waited. Nothing to send it to.
    if (target == null) return;

    // What this chat lets the agent do — its own choice when it has one, else
    // the app's standing one. Read once here so the turn runs under the mode
    // that was on screen when Send was pressed, even if the user switches chats
    // (or modes) while it streams.
    final approval = approvalFor(target, ref.read(chatPrefsProvider).approval);

    // Plan mode's planning turn: only when the composer is set to Plan (unless
    // the caller forced it — the approve path forces it off) and the agent is
    // the one answering, since a relay/media turn has no plan/act split.
    final planTurn =
        (planFirst ?? approval == AgentApprovalMode.plan) &&
        agentAnswersTurn(
          modality: modality,
          hasAttachments: attachments.isNotEmpty,
          agentInstalled: ref.read(anyAgentInstalledProvider),
        );

    // Append the user turn and persist it up front, so an interrupted reply
    // never loses what the user typed. A new compose becomes a real, saved
    // conversation here. Attached images (vision) are saved to disk so they
    // render, persist and can be re-encoded into the request.
    final userTurn = await buildUserTurn(
      text: text,
      attachments: attachments,
      outputsDir: ref.read(mediaOutputsDirProvider),
    );
    final withUser = target.copyWith(
      model: model,
      updatedAt: DateTime.now(),
      messages: [...target.messages, userTurn],
    );
    // A chat is named once — from its first message, until the agent replaces
    // that with a name for what it's actually about. Re-deriving on every turn
    // would drag it back to the first line the user typed ("hi") and undo that.
    final conversation = withUser.title == kNewConversationTitle
        ? withUser.copyWith(title: deriveConversationTitle(withUser.messages))
        : withUser;
    // The send owns the open slot: make it active and clear any prior error. A
    // queued follow-up doesn't — it goes out into a chat the user may have left,
    // and nothing the app sends on its own may pull them back to it.
    _commit(conversation, phase: const SendBusy(), makeActive: into == null);

    final id = conversation.id;
    final done = _dones[id] = Completer<void>();
    final project = ref.read(projectByIdProvider(conversation.projectId));
    // Plain text goes through the agent (it can use tools and keeps the
    // conversation's context); pictures — generating one, or a turn that carries
    // attachments — go straight to the grid's chat API, which is the only one
    // that can see or make them.
    final viaAgent = agentAnswersTurn(
      modality: modality,
      hasAttachments: attachments.isNotEmpty,
      agentInstalled: ref.read(anyAgentInstalledProvider),
    );

    void dispatch() => _dispatch(
      conversation: conversation,
      network: network,
      model: model,
      modality: modality,
      attachments: attachments,
      workdir: project?.path,
      // Both the project's house rules and the facts it's been asked to
      // remember — one standing brief the agent reads on its first turn.
      instructions: project == null ? null : projectStandingBrief(project),
      planTurn: planTurn,
      approval: approval,
      viaAgent: viaAgent,
      done: done,
    );

    // Serialize agent turns (see [ChatSessionsState.runningAgentId]): a second
    // one waits its turn rather than running concurrently and corrupting the
    // first's session and permission card. The chat sits in its [SendBusy]
    // "thinking" state until the slot frees. Relay/media turns share none of
    // that and go straight out, still fully concurrent.
    if (viaAgent &&
        state.runningAgentId != null &&
        state.runningAgentId != id) {
      _agentQueue.add((id: id, dispatch: dispatch));
    } else {
      dispatch();
    }
    return done.future;
  }

  /// Send [conversation]'s turn to its [ChatSender] and fold the reply back in.
  ///
  /// Split out from [send] so an agent turn can be deferred (see [_agentQueue])
  /// and dispatched later with the same committed history. The subscription is
  /// keyed by conversation, so [stop] and disposal cancel exactly this reply and
  /// it never writes back into the wrong chat after the user has moved on.
  void _dispatch({
    required Conversation conversation,
    required NetworkCredential network,
    required String model,
    required PlaygroundModality modality,
    required List<MediaAttachment> attachments,
    required String? workdir,
    required String? instructions,
    required bool planTurn,
    required AgentApprovalMode approval,
    required bool viaAgent,
    required Completer<void> done,
  }) {
    final id = conversation.id;
    // Claim the agent's single turn slot — released on finish/stop, which then
    // starts the next queued agent turn — and with it the files this turn is
    // about to change, so its undo stays with this chat even when the user has
    // moved to another one by the time the agent writes.
    if (viaAgent) {
      state = state.copyWith(runningAgentId: id);
      ref.read(agentChangesProvider.notifier).attributeTo(id);
    }

    // How long the answer takes, timed from here rather than from `send`: an
    // agent turn can sit in the queue behind another chat, and charging it for
    // that wait would tell the user this model is slow when another chat was
    // simply holding the slot.
    final clock = Stopwatch()..start();
    // When the first word of the answer appeared. Set once, on the first
    // streamed text: every later update carries the whole answer so far, so
    // reading any of them would time the last word instead of the first.
    Duration? firstToken;

    final updates = _senderFor(modality, attachments).send(
      network: network,
      model: model,
      history: conversation.messages,
      modality: modality,
      attachments: attachments,
      // The chat's project, so the agent answers with that folder open. Null for
      // a chat that belongs to no project (it falls back to the app's folder).
      workdir: workdir,
      // The project's house rules, prepended to the agent's first turn.
      instructions: instructions,
      // Lets the agent sender keep one live session per conversation and send
      // only the new turn (the API sender ignores it).
      conversationId: id,
      // A planning turn runs read-only and asks the agent to lay out a plan.
      planFirst: planTurn,
      // This chat's own permission level, not the app's — a turn dispatched
      // into a background chat must run under that chat's rules.
      approval: approval,
    );

    String? agentSessionId;
    _subs[id] = updates.listen(
      (update) {
        // The conversation may have been deleted mid-flight — drop the update
        // rather than resurrect it.
        final current = _find(id);
        if (current == null) return;
        switch (update) {
          case ChatSendGenerating(:final progress, :final status):
            state = state.withPhase(
              id,
              SendGenerating(progress: progress, status: status),
            );
          case ChatSendStreaming(:final text):
            if (firstToken == null && text.trim().isNotEmpty) {
              firstToken = clock.elapsed;
            }
            state = state.withPhase(id, SendStreaming(text));
          case ChatSendAgentSession(:final sessionId):
            agentSessionId = sessionId;
          case ChatSendSuccess(:final reply):
            final answered = current.copyWith(
              updatedAt: DateTime.now(),
              // Stamp the reply with the model that answered, so the transcript
              // says which one spoke even after switching models mid-chat.
              messages: [
                ...current.messages,
                reply.copyWith(
                  model: model,
                  took: clock.elapsed,
                  firstToken: firstToken,
                ),
              ],
            );
            // A planning turn's reply is a plan waiting on approval — light the
            // "approve & run" bar for this chat. Any other reply leaves it dark.
            // Does not steal focus: a reply landing in a background chat leaves
            // whatever the user is reading open.
            _commit(answered, phase: const SendIdle(), awaitingPlan: planTurn);
            _adoptAgentName(answered, agentSessionId);
            _announceTurn(answered, body: firstLinePreview(reply.text));
          case ChatSendFailure(:final error, :final partial):
            // Keep what the assistant produced before it failed — its streamed
            // prose, the plan it laid out — instead of wiping the turn to a bare
            // error line, which reads as "it did nothing". The error still
            // shows, with its retry / switch-agent affordance. Mirrors stop();
            // the streamed text is the fallback for a relay turn that carries no
            // structured partial of its own.
            final phase = state.phaseFor(id);
            final streamed = phase is SendStreaming ? phase.text.trim() : '';
            final kept =
                partial ??
                (streamed.isEmpty
                    ? null
                    : ChatMessage(role: ChatRole.assistant, text: streamed));
            if (kept == null) {
              state = state
                  .withPhase(id, const SendIdle())
                  .withError(id, error);
            } else {
              _commit(
                current.copyWith(
                  updatedAt: DateTime.now(),
                  messages: [
                    ...current.messages,
                    // The part-answer is stamped too: a turn that died after
                    // four minutes and one that died instantly are different
                    // problems.
                    kept.copyWith(
                      model: model,
                      took: clock.elapsed,
                      firstToken: firstToken,
                    ),
                  ],
                ),
                phase: const SendIdle(),
              );
              // _commit clears the error; set it after so the line still shows
              // above the kept reply.
              state = state.withError(id, error);
            }
            _announceTurn(current, body: "Couldn't finish: $error");
        }
      },
      onDone: () => _finish(id),
      onError: (Object _) => _finish(id),
      cancelOnError: true,
    );
  }

  /// Tell the desktop that [conversation] is done, unless the user is already
  /// watching it happen.
  ///
  /// An agent turn can run for minutes, and the reason to leave the app during
  /// one is that it doesn't need watching — so a reply that lands in silence is
  /// a reply the user finds twenty minutes late. A turn that *failed* is
  /// announced on the same terms: they are otherwise still waiting on an answer
  /// that is never coming.
  ///
  /// [body] is already the one line to show (see [firstLinePreview]).
  void _announceTurn(Conversation conversation, {required String body}) {
    final worthIt = notificationIsWorthIt(
      appFocused: ref.read(windowFocusedProvider),
      userIsLookingAtIt: state.activeId == conversation.id,
    );
    if (!worthIt) return;
    unawaited(
      ref
          .read(desktopNotifierProvider)
          .show(
            DesktopNotification(
              title: conversation.title,
              body: body,
              opens: conversation.id,
            ),
          ),
    );
  }

  /// Let the agent name the chat, replacing the placeholder taken from the first
  /// message ("hi") with what the conversation turned out to be about.
  ///
  /// The agent names a session once, off its opening exchange, so this only runs
  /// on the first reply — a later turn (or reopening the chat weeks on) must not
  /// rename a conversation the user already knows by its name.
  void _adoptAgentName(Conversation conversation, String? sessionId) {
    if (sessionId == null || conversation.messages.length != 2) return;
    unawaited(_rename(conversation.id, sessionId));
  }

  /// Wait for the name, then swap it in — without re-sorting or stealing focus,
  /// since by now the user may well be reading a different chat.
  Future<void> _rename(String conversationId, String sessionId) async {
    final title = await ref.read(agentSessionTitleProvider).waitFor(sessionId);
    if (title == null || _disposed) return;

    // Re-read *after* the wait, not before: the name takes seconds to arrive,
    // and the user may have named the chat themselves in the meantime. Theirs
    // wins — this is the only thing standing between a hand-typed title and an
    // agent silently replacing it.
    final current = _find(conversationId);
    if (current == null || current.titleLocked || current.title == title) {
      return;
    }
    final renamed = current.copyWith(title: title);
    _store.save(renamed);
    state = state.copyWith(
      conversations: [
        for (final c in state.conversations)
          if (c.id == conversationId) renamed else c,
      ],
    );
  }

  /// Who answers this turn: the agent for plain text, the grid's chat API for
  /// anything with a picture in it (and on a computer with no agent installed).
  ChatSender _senderFor(
    PlaygroundModality modality,
    List<MediaAttachment> attachments,
  ) {
    final viaAgent = agentAnswersTurn(
      modality: modality,
      hasAttachments: attachments.isNotEmpty,
      agentInstalled: ref.read(anyAgentInstalledProvider),
    );
    return viaAgent
        ? ref.read(chatAgentSenderProvider)
        : ref.read(chatSenderProvider);
  }

  /// Stop the **open** chat's in-flight reply, keeping whatever the assistant had
  /// already said. A reply streaming in another chat is left running.
  ///
  /// The user's turn is persisted up front, but a half-written answer lives only
  /// in [SendStreaming] — dropping it would wipe text the user is reading, and
  /// they usually stop *because* they've read enough of it. Nothing streamed yet
  /// (the agent still thinking) means there's nothing to keep.
  void stop() {
    final id = state.activeId;
    if (id == null || !state.sendingFor(id)) return;
    final phase = state.phaseFor(id);
    _cancel(id);

    final partial = phase is SendStreaming ? phase.text.trim() : '';
    final current = state.active;
    if (partial.isEmpty || current == null) {
      state = state.withPhase(id, const SendIdle());
      return;
    }
    _commit(
      current.copyWith(
        updatedAt: DateTime.now(),
        messages: [
          ...current.messages,
          ChatMessage(role: ChatRole.assistant, text: partial),
        ],
      ),
      phase: const SendIdle(),
    );
  }

  /// Hold [turn] until the open chat has finished answering.
  void _enqueue(QueuedTurn turn) {
    final id = state.activeId;
    if (id == null) return;
    state = state.withQueue(id, [...state.queuedFor(id), turn]);
  }

  /// Drop the follow-up at [index] in the chat [id] — the user changed their
  /// mind before it went out.
  void cancelQueued(String id, int index) {
    final waiting = [...state.queuedFor(id)];
    if (index < 0 || index >= waiting.length) return;
    waiting.removeAt(index);
    state = state.withQueue(id, waiting);
  }

  /// Send the next follow-up waiting in the chat [id], if any.
  ///
  /// One at a time, and only once the turn before it has settled: the whole
  /// point of the queue is that these are consecutive turns of one conversation,
  /// so firing them together would have them race for the agent's session.
  void _drainQueue(String id) {
    final waiting = state.queuedFor(id);
    if (waiting.isEmpty) return;
    final next = waiting.first;
    state = state.withQueue(id, waiting.sublist(1));
    unawaited(
      send(
        network: next.network,
        model: next.model,
        message: next.text,
        modality: next.modality,
        attachments: next.attachments,
        into: id,
      ),
    );
  }

  /// Settle one conversation's send: drop its subscription and complete the
  /// future [send] returned (whether it finished on its own or was cancelled).
  void _finish(String id) {
    _subs.remove(id);
    final done = _dones.remove(id);
    if (done != null && !done.isCompleted) done.complete();
    _releaseAgentSlot(id);
    _drainQueue(id);
  }

  /// Cancel one conversation's in-flight reply (if any) and settle it. Also
  /// drops it from [_agentQueue] in case it was still waiting to dispatch, and
  /// from the follow-up queue: Stop means stop, so a message typed behind the
  /// turn being abandoned is abandoned with it rather than firing a second later
  /// as if nothing had happened. The composer shows what is waiting, so this is
  /// something the user can see go.
  void _cancel(String id) {
    final sub = _subs.remove(id);
    sub?.cancel();
    _agentQueue.removeWhere((queued) => queued.id == id);
    // Not while the controller is being torn down: `_cancelAll` runs from
    // `ref.onDispose`, and Riverpod forbids touching state there. The queue is
    // in-memory anyway, so a disposal takes it with it.
    if (!_disposed) state = state.withQueue(id, const []);
    final done = _dones.remove(id);
    if (done != null && !done.isCompleted) done.complete();
    _releaseAgentSlot(id);
  }

  /// Free the agent's single turn slot when [id] held it, then start the next
  /// waiting agent turn. A no-op for a relay turn or a background chat that
  /// never held the slot.
  ///
  /// Silent during disposal: this is reached from `ref.onDispose` (via
  /// [_cancelAll]) whenever the app is torn down with an agent turn in flight,
  /// and Riverpod asserts on any state written there. There is also nothing left
  /// to free — the whole controller is going.
  void _releaseAgentSlot(String id) {
    if (_disposed || state.runningAgentId != id) return;
    state = state.copyWith(runningAgentId: null);
    _pumpAgentQueue();
  }

  /// Dispatch the oldest queued agent turn whose chat is still around, if the
  /// slot is free. One at a time: [dispatch] claims the slot again.
  void _pumpAgentQueue() {
    while (state.runningAgentId == null && _agentQueue.isNotEmpty) {
      final next = _agentQueue.removeAt(0);
      // Skip a turn whose chat was deleted, or whose send was already settled,
      // while it waited — its future is (or will be) completed by [_cancel].
      final done = _dones[next.id];
      if (done == null || done.isCompleted || _find(next.id) == null) continue;
      next.dispatch();
    }
  }

  /// Tear down every in-flight reply — for disposal.
  void _cancelAll() {
    for (final id in _subs.keys.toList()) {
      _cancel(id);
    }
    // Queued turns never got a subscription; complete their futures too.
    for (final queued in _agentQueue.toList()) {
      _cancel(queued.id);
    }
  }

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
}
