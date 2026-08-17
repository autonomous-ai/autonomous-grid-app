import '../../../infrastructure/state/models/network_credential.dart';
import '../../playground/logic/chat_message.dart';
import '../../playground/logic/playground_request.dart';
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
    this.files = const [],
    this.contexts = const [],
  });

  final NetworkCredential network;
  final String model;
  final String text;
  final PlaygroundModality modality;
  final List<MediaAttachment> attachments;

  /// The documents attached to the queued message — carried with it so a file
  /// picked now still goes out with the sentence it belonged to.
  final List<ChatFile> files;

  /// What was on screen when the user pressed Send, captured then rather than
  /// when the queue drains: a follow-up typed while the agent works can wait
  /// minutes, and the terminal it was about has moved on by the time it goes.
  final List<ChatContext> contexts;
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
    this.outOfStepsIds = const {},
    this.carriedOn = const {},
    this.runningAgents = const {},
    this.turnStartedAt = const {},
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

  /// The conversations whose **agent** turn is running right now, each mapped to
  /// the id of the agent answering it (`hermes`, `codex`, …).
  ///
  /// More than one, because turns are serialized **per project**, not app-wide:
  /// two chats in the same folder would trip over each other's files, so they
  /// queue; two projects (and any chat outside every project) have nothing in
  /// common and run at the same time. Everything a turn publishes — its steps,
  /// its permission request, the files it changed — is keyed by conversation for
  /// exactly this reason.
  ///
  /// The UI reads this to show the "agent is working" steps on a chat that is
  /// running — including the ones the user is not looking at, since several
  /// chats can be working at once. The agent's *id* rather than a bare
  /// membership flag because "Working now" names who is answering each chat, and
  /// under Auto that is decided per turn — the chat's own pick would be a guess.
  final Map<String, String> runningAgents;

  /// When each in-flight turn went out, keyed by conversation id — what
  /// "Working now" counts its elapsed time from.
  ///
  /// Written when the turn is actually dispatched, not when Send was pressed: a
  /// turn held behind another would otherwise be charged for a wait that was the
  /// app's doing. Dropped the moment the chat goes idle (see [withPhase]), so
  /// this only ever holds turns that are still running.
  final Map<String, DateTime> turnStartedAt;

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

  /// Conversations whose last turn ran out of the tool calls one turn is allowed
  /// while its plan was still unfinished ([agentSpentToolBudget]): the chat shows
  /// a "carry on" bar. Live interaction state like [awaitingPlanIds] — cleared by
  /// the next commit in that chat, and never saved with the conversation.
  final Set<String> outOfStepsIds;

  /// How many turns each chat has carried on **by itself** since the user last
  /// said something (issue #28).
  ///
  /// A budget, not a tally: the app continues an unfinished turn without being
  /// asked, and this is what stops that from becoming a loop nobody is watching.
  /// Spent one turn at a time and cleared by the next thing the user sends, so a
  /// second instruction gets its own allowance rather than inheriting what the
  /// first one used up. In memory only — it belongs to the run of turns being
  /// worked, not to the conversation.
  final Map<String, int> carriedOn;

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

  /// Whether the chat with [id] has an **agent** turn running right now — as
  /// opposed to a relay turn, or nothing at all.
  bool agentRunningIn(String? id) =>
      id != null && runningAgents.containsKey(id);

  /// The id of the agent answering the chat with [id], or null when the grid
  /// itself is (a picture, or a computer with no agent installed).
  String? agentRunningId(String? id) => id == null ? null : runningAgents[id];

  /// When the chat with [id]'s turn went out, or null when it isn't running.
  DateTime? turnStartFor(String? id) => id == null ? null : turnStartedAt[id];

  /// The last error on the chat with [id], or null.
  String? errorFor(String? id) => id == null ? null : errors[id];

  /// Whether the chat with [id] has a plan waiting on approval.
  bool awaitingPlanFor(String? id) =>
      id != null && awaitingPlanIds.contains(id);

  /// Whether the chat with [id] stopped last turn for want of tool calls.
  bool outOfStepsFor(String? id) => id != null && outOfStepsIds.contains(id);

  /// How many turns the chat with [id] has carried on by itself.
  int carriedOnFor(String? id) => id == null ? 0 : (carriedOn[id] ?? 0);

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

  /// Whether the open conversation's last turn ran out of room mid-plan.
  bool get outOfSteps => outOfStepsFor(activeId);

  /// How many turns the open conversation has carried on by itself — what the
  /// "carry on" bar reports, so a user who left the room can read what the app
  /// did while they were gone.
  int get carriedOnHere => carriedOnFor(activeId);

  ChatSessionsState copyWith({
    List<Conversation>? conversations,
    Object? activeId = _keep,
    Object? draftProjectId = _keep,
    Map<String, SendPhase>? phases,
    Map<String, String?>? errors,
    Set<String>? awaitingPlanIds,
    Set<String>? outOfStepsIds,
    Map<String, int>? carriedOn,
    Map<String, String>? runningAgents,
    Map<String, DateTime>? turnStartedAt,
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
    outOfStepsIds: outOfStepsIds ?? this.outOfStepsIds,
    carriedOn: carriedOn ?? this.carriedOn,
    runningAgents: runningAgents ?? this.runningAgents,
    turnStartedAt: turnStartedAt ?? this.turnStartedAt,
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
  ///
  /// Going idle also drops the turn's start time: this is the one funnel every
  /// landing goes through — the answer, the failure, the half-turn Stop kept —
  /// so clearing it here is what keeps [turnStartedAt] from outliving the turn
  /// it timed.
  ChatSessionsState withPhase(String id, SendPhase phase) {
    final next = Map<String, SendPhase>.from(phases);
    if (phase is! SendIdle) {
      next[id] = phase;
      return copyWith(phases: next);
    }
    next.remove(id);
    return copyWith(
      phases: next,
      turnStartedAt: {
        for (final e in turnStartedAt.entries)
          if (e.key != id) e.key: e.value,
      },
    );
  }

  /// This state with the chat [id]'s turn timed from [at] — what "Working now"
  /// counts up from.
  ChatSessionsState withTurnStarted(String id, DateTime at) =>
      copyWith(turnStartedAt: {...turnStartedAt, id: at});

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

  /// This state with the chat [id]'s carry-on budget set to [turns] — dropped
  /// from the map at zero, so it only holds chats that have actually carried on.
  ChatSessionsState withCarriedOn(String id, int turns) {
    if (turns <= 0 && !carriedOn.containsKey(id)) return this;
    final next = Map<String, int>.from(carriedOn);
    if (turns <= 0) {
      next.remove(id);
    } else {
      next[id] = turns;
    }
    return copyWith(carriedOn: next);
  }

  /// This state with the chat [id]'s out-of-steps flag set or cleared.
  ChatSessionsState withOutOfSteps(String id, bool outOfSteps) {
    final next = Set<String>.from(outOfStepsIds);
    if (outOfSteps) {
      next.add(id);
    } else {
      next.remove(id);
    }
    return copyWith(outOfStepsIds: next);
  }

  /// Drop every trace of the chats in [ids] — their in-flight phase, start time,
  /// error, plan flag and out-of-steps flag — for when they're deleted.
  ChatSessionsState withoutInFlight(Set<String> ids) => copyWith(
    phases: {
      for (final e in phases.entries)
        if (!ids.contains(e.key)) e.key: e.value,
    },
    turnStartedAt: {
      for (final e in turnStartedAt.entries)
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
    outOfStepsIds: {
      for (final id in outOfStepsIds)
        if (!ids.contains(id)) id,
    },
    carriedOn: {
      for (final e in carriedOn.entries)
        if (!ids.contains(e.key)) e.key: e.value,
    },
  );
}
