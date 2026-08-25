import 'routing_group.dart';
import 'turn_model_share.dart';
import '../../../infrastructure/cli/model_control_tokens.dart';
import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/cli/agent_resume_point.dart';
import 'commands/chat_compaction.dart';
import 'commands/chat_goal.dart';
import 'commands/chat_loop.dart';
import '../../playground/logic/chat_message.dart';
import '../../playground/logic/message_media.dart';

/// A saved Chat conversation — the persistent counterpart to the Playground's
/// throwaway transcript. Holds its turns plus the model last used to answer in
/// it, so reopening restores both the history and the picker. Serialized one
/// file per conversation under `~/.grid/app/chats/<id>.json`.
class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.model,
    required this.createdAt,
    required this.updatedAt,
    this.messages = const [],
    this.projectId,
    this.titleLocked = false,
    this.titleFromModel = false,
    this.archivedAt,
    this.approval,
    this.pinned = false,
    this.goal,
    this.loop,
    this.compaction,
    this.resume,
    this.documentPath,
    this.lastRequestWatermark,
    this.routingGroup,
  });

  final String id;

  /// Short human label for the sidebar — derived from the first user message
  /// (`deriveConversationTitle`), then replaced by the name a model gave the
  /// conversation (`ChatTitleWriter`); [kNewConversationTitle] until then.
  final String title;

  /// The model id last chosen in this conversation, restored into the picker.
  final String model;

  final DateTime createdAt;
  final DateTime updatedAt;
  final List<ChatMessage> messages;

  /// The project (a folder on this computer) this chat was opened inside, or
  /// null for a chat that belongs to no project. It decides which files the
  /// assistant may read while answering — see `Project`.
  final String? projectId;

  /// The user named this chat by hand, so nothing may rename it again.
  ///
  /// The agent names a chat off its opening exchange, but that name arrives
  /// seconds *after* the first reply — long enough for the user to have already
  /// typed their own. Persisted rather than kept in memory: the agent's rename
  /// can land after a restart, and a title the user chose must outlive the
  /// session that chose it.
  final bool titleLocked;

  /// A model wrote the name this chat is wearing — the agent's own name for its
  /// session, or one asked for after it.
  ///
  /// False means the chat is still wearing the line derived from what the user
  /// typed, and that is what lets a **later** turn try again. Naming used to get
  /// exactly one attempt, on the first reply: a chat whose only model happened
  /// to be unreachable that minute kept "Help me edit this…" for good, which is
  /// the half of issue #37 the naming pass itself couldn't fix.
  ///
  /// Persisted, or quitting the app would put every named chat back in the queue
  /// to be named again. A chat saved before this field existed reads as false
  /// and so gets named on its next turn — a one-off, and the chats it touches
  /// are the badly-named ones this was written for.
  final bool titleFromModel;

  /// When the user archived this chat, or null while it's live.
  ///
  /// Archiving is *hiding*, not deleting: the transcript is untouched and the
  /// chat comes back whole on unarchive. Stored as the moment it happened
  /// rather than a bool so the Archived screen can sort by when each chat was
  /// put away — which is the order the user actually remembers filing them in,
  /// and is independent of [updatedAt] (when it was last talked in).
  final DateTime? archivedAt;

  /// How much the assistant may do without asking **in this chat**, or null when
  /// the chat has never been told and follows the app's standing choice.
  ///
  /// Per chat, not per app, because the mode is a decision about one piece of
  /// work: turning on full access to let the agent rebuild a project used to
  /// leave *every* chat — including the next one, about something else
  /// entirely — running without asking, with nothing on screen saying so. Null
  /// rather than a default value so a chat saved before this existed keeps
  /// following the app setting instead of freezing whatever it was that day.
  final AgentApprovalMode? approval;

  /// The user pinned this chat to the top of the sidebar.
  ///
  /// The rail is ordered by when a chat was last talked in, which is right for
  /// finding what you were just doing and wrong for the two or three
  /// conversations you keep coming back to — those slide down a little further
  /// every day until they're behind a "Show more". A pin takes one out of that
  /// order without changing what the order means.
  final bool pinned;

  /// What this chat is working toward on its own, or null for an ordinary
  /// back-and-forth. See [ChatGoal].
  final ChatGoal? goal;

  /// The prompt this chat re-runs on a timer, or null. See [ChatLoop].
  final ChatLoop? loop;

  /// Where this chat's context was summarized, or null while it carries its
  /// whole history. See [ChatCompaction].
  final ChatCompaction? compaction;

  /// The agent session this chat can carry on from, or null when the next
  /// message has to start a fresh one. See [AgentResumePoint].
  ///
  /// Two chats need this and they are the same need. A chat *imported* from
  /// Claude Code or Codex has a session this app never opened, and continuing
  /// it is the difference between a transcript and a conversation. A chat this
  /// app started has one too — but only in memory, so quitting the app used to
  /// throw it away and replay the entire history into a new session on the next
  /// message.
  final AgentResumePoint? resume;

  /// The document in Docs this chat belongs to, or null for an ordinary chat.
  ///
  /// Docs pairs one conversation with one file: the chat beside a document is
  /// *that document's* chat, so "make the heading shorter" a week later still
  /// means the heading in this file. It is also what makes the row in the
  /// sidebar work — clicking a chat with a path here opens Docs with the file
  /// on the right, not the Chat screen with a conversation about a document
  /// nobody can see.
  ///
  /// Persisted, and that is the whole reason it lives on the conversation
  /// rather than in a map beside it: the pairing used to be session state, so
  /// quitting the app left a sidebar full of chats named after files that no
  /// longer opened any.
  final String? documentPath;

  /// The cursor the grid returned with this chat's last request, or null
  /// before any request has gone out.
  ///
  /// Opaque to the app — it exists only to be sent back on the next request
  /// so the grid can resume from where this chat's polling left off, rather
  /// than replaying answers it already delivered.
  final String? lastRequestWatermark;

  /// The routing mode and models this chat is pinned to, or null for the
  /// grid's ordinary pick. See [RoutingGroup].
  final RoutingGroup? routingGroup;

  /// True when this chat is hidden from the sidebar, the tray and ⌘K.
  bool get isArchived => archivedAt != null;

  /// [archivedAt] can't use the usual `?? this.archivedAt` idiom: unarchiving
  /// means setting it *back to null*, which that idiom can't express (it would
  /// read the null as "leave it alone" and the chat could never come back).
  /// Passing [clearArchivedAt] is how a caller says null on purpose.
  Conversation copyWith({
    String? title,
    String? model,
    DateTime? updatedAt,
    List<ChatMessage>? messages,
    // Only ever *set* a project here (null keeps the current one): a chat leaves
    // its project by being deleted, not re-homed, so there's no clear path to
    // express and the plain `?? this` idiom is exactly right.
    String? projectId,
    bool? titleLocked,
    // Only ever *set*: a name a model wrote does not stop being one. It is
    // cleared by nothing, because nothing puts a chat back to the line it was
    // derived from.
    bool? titleFromModel,
    DateTime? archivedAt,
    bool clearArchivedAt = false,
    // Only ever *set*: a chat that has been given its own mode keeps it. Going
    // back to "follow the app setting" isn't something the picker offers — every
    // mode in it is a real choice.
    AgentApprovalMode? approval,
    bool? pinned,
    ChatGoal? goal,
    // A goal is *removed*, not merely changed, when the user clears it — which
    // the `?? this` idiom can't say.
    bool clearGoal = false,
    // Only ever *set*: a loop that has stopped stays on the conversation, the
    // way a compaction does. That is what draws the line saying it stopped at
    // the point in the transcript where it did (`endedAfter`) — removing it
    // would take the news out of the history with it.
    ChatLoop? loop,
    ChatCompaction? compaction,
    // Only ever *set*: a session that can be resumed goes on being resumable
    // until it is replaced by a newer one. It is dropped by the sender at the
    // moment it fails, not by a caller here — except on a compaction, which
    // starts the agent's own session afresh from the summary. Leaving it would
    // hand the agent back the very history the summary replaced, and free
    // nothing at all.
    AgentResumePoint? resume,
    bool clearResume = false,
    // Only ever *set*, like [projectId]: a chat started beside a document goes
    // on being that document's chat. There is no gesture that unpairs them —
    // the way to a conversation about something else is a new chat.
    String? documentPath,
    String? lastRequestWatermark,
    // Only ever *set*, like [documentPath]: a chat pinned to a routing mode
    // stays pinned until the picker explicitly asks to go back to the grid's
    // own choice, which is what [clearRoutingGroup] says.
    RoutingGroup? routingGroup,
    bool clearRoutingGroup = false,
  }) => Conversation(
    id: id,
    title: title ?? this.title,
    model: model ?? this.model,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    messages: messages ?? this.messages,
    projectId: projectId ?? this.projectId,
    titleLocked: titleLocked ?? this.titleLocked,
    titleFromModel: titleFromModel ?? this.titleFromModel,
    archivedAt: clearArchivedAt ? null : (archivedAt ?? this.archivedAt),
    approval: approval ?? this.approval,
    pinned: pinned ?? this.pinned,
    goal: clearGoal ? null : (goal ?? this.goal),
    loop: loop ?? this.loop,
    compaction: compaction ?? this.compaction,
    resume: clearResume ? null : (resume ?? this.resume),
    documentPath: documentPath ?? this.documentPath,
    lastRequestWatermark: lastRequestWatermark ?? this.lastRequestWatermark,
    routingGroup: clearRoutingGroup
        ? null
        : (routingGroup ?? this.routingGroup),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'model': model,
    'projectId': projectId,
    'titleLocked': titleLocked,
    // Written only when true, so a chat still wearing its derived name is saved
    // byte-identically to what every build before this wrote.
    if (titleFromModel) 'titleFromModel': true,
    // UTC, so the `Z` is on the wire: these files travel between machines now
    // (Settings ▸ Sync & Backup), and a local-time stamp with no zone reads as
    // the *reader's* zone — a chat written at 15:00 in Hanoi would look newer
    // than one written at 16:00 in Berlin, and the merge would keep the wrong
    // one. [_parseDate] still accepts the zoneless form every older file has.
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    // Written only when set, so a live chat's file is byte-identical to what
    // every build before archiving existed wrote.
    if (archivedAt != null) 'archivedAt': archivedAt!.toUtc().toIso8601String(),
    // Same rule: absent means "follows the app setting", which is what every
    // chat written before this field existed meant.
    if (approval != null) 'approval': approval!.name,
    // Written only when set, like the two above, so an unpinned chat's file is
    // byte-identical to what every build before pinning existed wrote.
    if (pinned) 'pinned': true,
    if (goal != null) 'goal': goal!.toJson(),
    if (loop != null) 'loop': loop!.toJson(),
    if (compaction != null) 'compaction': compaction!.toJson(),
    // Same rule again: absent means "start a fresh session", which is what
    // every chat saved before this field existed did.
    if (resume != null) 'resume': resume!.toJson(),
    // Same rule once more: absent means an ordinary chat, which is what every
    // conversation written before Docs existed is.
    if (documentPath != null) 'documentPath': documentPath,
    // Same rule again: absent means "no request has gone out yet", which is
    // what every chat written before polling could resume was.
    if (lastRequestWatermark != null)
      'lastRequestWatermark': lastRequestWatermark,
    // Same rule once more: absent means the grid's own pick, which is what
    // every chat written before routing modes existed used.
    if (routingGroup != null) 'routingGroup': routingGroup!.toJson(),
    'messages': [for (final m in messages) _messageToJson(m)],
  };

  /// Rebuilds a conversation from stored JSON, tolerating missing/renamed
  /// fields so one hand-edited file never bricks the whole history. Throws only
  /// when there's no usable [id] — the store drops such files.
  factory Conversation.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('conversation is missing an id');
    }
    final rawMessages = json['messages'];
    return Conversation(
      id: id,
      title: json['title'] is String && (json['title'] as String).isNotEmpty
          ? json['title'] as String
          : kNewConversationTitle,
      model: json['model'] is String ? json['model'] as String : '',
      projectId:
          json['projectId'] is String &&
              (json['projectId'] as String).isNotEmpty
          ? json['projectId'] as String
          : null,
      // Defaults to false, so every chat saved before this field existed stays
      // open to the agent's naming — which is what it had all along.
      titleLocked: json['titleLocked'] == true,
      titleFromModel: json['titleFromModel'] == true,
      createdAt: _parseDate(json['createdAt']),
      updatedAt: _parseDate(json['updatedAt']),
      // Absent (every chat saved before this field existed) or unparseable
      // means live — the safe reading, since it keeps the chat visible rather
      // than hiding it in a screen the user hasn't learned about yet.
      archivedAt: _parseNullableDate(json['archivedAt']),
      // An unknown name (a mode this build has dropped) reads as "not set" —
      // following the app setting is the recoverable answer; guessing a mode
      // would be guessing how much this chat may touch the computer.
      approval: _approvalFrom(json['approval']),
      // Absent — every chat saved before this field existed — means unpinned,
      // which is what they all were.
      pinned: json['pinned'] == true,
      goal: ChatGoal.fromJson(json['goal']),
      loop: ChatLoop.fromJson(json['loop']),
      compaction: ChatCompaction.fromJson(json['compaction']),
      // A point that won't parse reads as none, which costs a replay — the same
      // thing that happens to every chat written before this existed.
      resume: AgentResumePoint.fromJson(json['resume']),
      // An empty string reads as none: a chat paired with "" would open Docs
      // and then fail to find a file, which is worse than an ordinary chat.
      documentPath:
          json['documentPath'] is String &&
              (json['documentPath'] as String).isNotEmpty
          ? json['documentPath'] as String
          : null,
      // An empty string reads as none, the same reasoning as documentPath: a
      // blank cursor is not a cursor to resume from.
      lastRequestWatermark:
          json['lastRequestWatermark'] is String &&
              (json['lastRequestWatermark'] as String).isNotEmpty
          ? json['lastRequestWatermark'] as String
          : null,
      // Unparseable (a shape this build no longer understands) reads as
      // none — the recoverable answer, since it hands the chat back to the
      // grid's own pick instead of guessing at a mode.
      routingGroup: json['routingGroup'] is Map<String, dynamic>
          ? RoutingGroup.tryFromJson(
              json['routingGroup'] as Map<String, dynamic>,
            )
          : null,
      messages: [
        if (rawMessages is List)
          for (final m in rawMessages)
            if (m is Map<String, dynamic>) _messageFromJson(m),
      ],
    );
  }
}

/// The saved mode name, or null for "not set" — including a name no build of
/// this app writes any more.
AgentApprovalMode? _approvalFrom(Object? raw) {
  if (raw is! String) return null;
  for (final mode in AgentApprovalMode.values) {
    if (mode.name == raw) return mode;
  }
  return null;
}

/// The placeholder title before a conversation has any user text.
const String kNewConversationTitle = 'New chat';

/// The chats in [all] that haven't been archived, in the order given — what any
/// screen showing the user their *working* history lists.
///
/// A plain function rather than only a getter on the sessions state, so the
/// sidebar can derive it from the conversation list alone and subscribe to just
/// that slice instead of the whole state.
List<Conversation> liveConversations(List<Conversation> all) => [
  // Pinned first, each group keeping the order it came in (newest talked-in
  // first). Done here rather than in each surface so the rail, the tray menu and
  // ⌘K can't drift into three different answers to "which chats matter".
  for (final c in all)
    if (!c.isArchived && c.pinned) c,
  for (final c in all)
    if (!c.isArchived && !c.pinned) c,
];

/// How many of [all] are live chats inside the project [projectId] — the count
/// the Projects screen and the project rail show, matching the rows the sidebar
/// actually lists under it.
int liveChatCountIn(List<Conversation> all, String projectId) {
  var count = 0;
  for (final c in all) {
    if (!c.isArchived && c.projectId == projectId) count++;
  }
  return count;
}

Map<String, dynamic> _messageToJson(ChatMessage message) => {
  'role': message.role.name,
  'text': message.text,
  'media': [
    for (final m in message.media) {'path': m.path, 'kind': m.kind.name},
  ],
  // Written whole, extracted text included: a reopened chat has to show what
  // was actually sent, and re-reading the file would answer for how it looks
  // today rather than for the version the reply was about.
  if (message.files.isNotEmpty)
    'files': [for (final f in message.files) f.toJson()],
  // Same reason as the files above: a reopened chat has to show what was sent,
  // and the terminal it was captured from has scrolled on since.
  if (message.contexts.isNotEmpty)
    'contexts': [for (final c in message.contexts) c.toJson()],
  if (message.sources.isNotEmpty)
    'sources': [for (final s in message.sources) s.toJson()],
  if (message.plan.isNotEmpty)
    'plan': [for (final p in message.plan) p.toJson()],
  // The turn's own order — what it said, and where the steps it ran sat between
  // those passages. Written only when an agent actually ran something, so a
  // plain reply's file is byte-identical to what every build before this wrote.
  //
  // Through [storedParts], which caps how many steps a single turn may put on
  // disk. An ordinary turn goes through untouched; the runaway ones a `/loop`
  // produces are what the cap is for.
  if (message.parts.isNotEmpty)
    'parts': [for (final p in storedParts(message.parts)) turnPartToJson(p)],
  if (message.agent != null) 'agent': message.agent,
  if (message.model != null) 'model': message.model,
  if (message.node != null) 'node': message.node,
  // Persisted so a transcript re-read next week still says what served the turn
  // — the same reason `node` is written down rather than re-derived.
  if (message.modelShares.isNotEmpty)
    'model_shares': [for (final s in message.modelShares) s.toJson()],
  // Same reason as model_shares: persisted so a reopened chat still says
  // exactly which models the grid's own usage log credited with this turn,
  // not only the live poll's guess.
  if (message.orchestrationModels != null)
    'orchestration_models': [
      for (final s in message.orchestrationModels!) s.toJson(),
    ],
  // Milliseconds, not a formatted string: the transcript re-renders it in
  // whatever shape the footer wants today, and a saved "8.4s" couldn't.
  if (message.took != null) 'took_ms': message.took!.inMilliseconds,
  if (message.firstToken != null)
    'first_token_ms': message.firstToken!.inMilliseconds,
  if (message.sentAt != null)
    'sent_at': message.sentAt!.toUtc().toIso8601String(),
  // Written only for the turns the app sent, so an ordinary chat's file is
  // byte-identical to what every build before this wrote — and so a transcript
  // saved by an older one reads back as the user's own words, which is what it
  // was (see [TurnOrigin]).
  if (message.sentBy.isFromApp) 'sent_by': message.sentBy.name,
};

ChatMessage _messageFromJson(Map<String, dynamic> json) {
  final rawMedia = json['media'];
  final rawFiles = json['files'];
  final rawContexts = json['contexts'];
  final rawSources = json['sources'];
  final rawPlan = json['plan'];
  final rawParts = json['parts'];
  final assistant = json['role'] == ChatRole.assistant.name;
  final text = json['text'] is String ? json['text'] as String : '';
  return ChatMessage(
    role: assistant ? ChatRole.assistant : ChatRole.user,
    // A reply saved before the transports learned to cut can carry the model's
    // chat-template markers, and everything the model invented after them (see
    // [stripControlTokens]). The user's own message is never touched: those
    // characters are theirs to have typed.
    text: assistant ? stripControlTokens(text) : text,
    media: [
      if (rawMedia is List)
        for (final m in rawMedia)
          if (m is Map<String, dynamic> && m['path'] is String)
            ChatMedia(path: m['path'] as String, kind: _parseKind(m['kind'])),
    ],
    files: [
      if (rawFiles is List)
        for (final f in rawFiles) ?ChatFile.fromJson(f),
    ],
    contexts: [
      if (rawContexts is List)
        for (final c in rawContexts) ?ChatContext.fromJson(c),
    ],
    sources: [
      if (rawSources is List)
        for (final s in rawSources)
          if (s is Map<String, dynamic>) ?WebSource.fromJson(s),
    ],
    plan: [
      if (rawPlan is List)
        for (final p in rawPlan)
          if (p is Map<String, dynamic>) ?AgentPlanEntry.fromJson(p),
    ],
    parts: [
      if (rawParts is List)
        for (final p in rawParts) ?turnPartFromJson(p),
    ],
    agent: json['agent'] is String ? json['agent'] as String : null,
    model: json['model'] is String ? json['model'] as String : null,
    node: json['node'] is String ? json['node'] as String : null,
    modelShares: json['model_shares'] is List
        ? [
            for (final row in json['model_shares'] as List)
              ?ModelShare.fromJson(row),
          ]
        : const [],
    // Absent — every chat saved before this existed, or a read that never
    // completed — reads as null, never as an empty reading.
    orchestrationModels: json['orchestration_models'] is List
        ? [
            for (final row in json['orchestration_models'] as List)
              ?ModelShare.fromJson(row),
          ]
        : null,
    took: json['took_ms'] is num
        ? Duration(milliseconds: (json['took_ms'] as num).toInt())
        : null,
    firstToken: json['first_token_ms'] is num
        ? Duration(milliseconds: (json['first_token_ms'] as num).toInt())
        : null,
    sentAt: _parseNullableDate(json['sent_at']),
    sentBy: _parseOrigin(json['sent_by']),
  );
}

/// The origin [raw] names, defaulting to the person.
///
/// A key nobody wrote, and a key written by a build that knows an origin this
/// one doesn't, both read as [TurnOrigin.user]: the turn is drawn as it always
/// was rather than as a line the reader can't open.
TurnOrigin _parseOrigin(Object? raw) {
  for (final origin in TurnOrigin.values) {
    if (origin.name == raw) return origin;
  }
  return TurnOrigin.user;
}

MediaKind _parseKind(Object? raw) {
  for (final kind in MediaKind.values) {
    if (kind.name == raw) return kind;
  }
  return MediaKind.image;
}

DateTime _parseDate(Object? raw) => _parseNullableDate(raw) ?? _epoch;

/// Like [_parseDate] but keeps null as null instead of falling back to the
/// epoch. Archiving is decided by *whether* this date is there, so the epoch
/// fallback would read every chat that has never been archived as archived in
/// 1970 and empty the sidebar on first launch.
///
/// Always returns a *local* [DateTime], whichever form the file used. Stamps
/// carry a `Z` since [Conversation.toJson] started writing UTC; the zoneless
/// form every older file has is read as this machine's local time, which is
/// what it was — the machine that wrote it is the machine reading it.
DateTime? _parseNullableDate(Object? raw) {
  if (raw is! String) return null;
  return DateTime.tryParse(raw)?.toLocal();
}

final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);

/// The approval mode [conversation] runs under, given the app's standing
/// [fallback].
///
/// Pure, and the one place the fallback rule lives: `chatApprovalModeProvider`
/// answers for the open chat, while a turn dispatched into a background chat
/// has to ask about that chat instead. It lives here rather than beside that
/// provider because the provider reads the chat controller, and the controller
/// needs this — a rule about a conversation belongs with the conversation.
AgentApprovalMode approvalFor(
  Conversation? conversation,
  AgentApprovalMode fallback,
) => conversation?.approval ?? fallback;

/// The string a turn in [conversation] puts in the request's `model` field,
/// given the [picked] model id the turn is actually going out on.
///
/// A chat pinned to a routing group sends the group instead: the mode's slash
/// string under Dynamic, the pinned model list under Fixed — see
/// [RoutingGroup.toModelField]. Everything the app shows about the turn keeps
/// naming [picked], because the Fixed form is a JSON object and a footer
/// answering "what answered this?" with one says nothing.
///
/// **Only while the chat is still on that mode.** The group alone is not
/// enough: the composer can be moved off a routing row without anything
/// clearing it — switch to a grid that serves no router and `_syncModelField`
/// drops the chat to a plain model, since the mode's row is no longer on the
/// list. The pill and the reply footer would then say `qwen` while every send
/// quietly carried the old grid's pinned ids, which is the app lying about
/// what it sent.
///
/// The check reads [Conversation.model] — the row the user is on — and never
/// [picked], which is what *this turn* goes out as. Under the Auto agent those
/// two differ on purpose: [picked] becomes the router's own `auto`, and
/// gating on it would drop Fixed routing for every agent turn that is
/// legitimately still pinned.
///
/// Pure, and here beside [approvalFor] for the same reason: a rule about a
/// conversation belongs with the conversation, not inside the send it decides.
String wireModelFor(Conversation conversation, String picked) {
  final group = conversation.routingGroup;
  if (group == null) return picked;
  if (routingModeForModelId(conversation.model) != group.mode) return picked;
  return group.toModelField();
}
