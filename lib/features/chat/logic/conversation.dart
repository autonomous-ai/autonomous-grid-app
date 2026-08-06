import '../../../infrastructure/cli/agent_event.dart';
import 'chat_goal.dart';
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
    this.archivedAt,
    this.approval,
    this.pinned = false,
    this.goal,
  });

  final String id;

  /// Short human label for the sidebar — derived from the first user message
  /// (see [deriveConversationTitle]); [kNewConversationTitle] until then.
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

  /// The objective this chat is working toward on its own, or null for an
  /// ordinary back-and-forth. See [ChatGoal].
  final ChatGoal? goal;

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
    DateTime? archivedAt,
    bool clearArchivedAt = false,
    // Only ever *set*: a chat that has been given its own mode keeps it. Going
    // back to "follow the app setting" isn't something the picker offers — every
    // mode in it is a real choice.
    AgentApprovalMode? approval,
    bool? pinned,
    ChatGoal? goal,
    // A goal is *removed*, not merely changed, when the user drops it — which
    // the `?? this` idiom can't say.
    bool clearGoal = false,
  }) => Conversation(
    id: id,
    title: title ?? this.title,
    model: model ?? this.model,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    messages: messages ?? this.messages,
    projectId: projectId ?? this.projectId,
    titleLocked: titleLocked ?? this.titleLocked,
    archivedAt: clearArchivedAt ? null : (archivedAt ?? this.archivedAt),
    approval: approval ?? this.approval,
    pinned: pinned ?? this.pinned,
    goal: clearGoal ? null : (goal ?? this.goal),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'model': model,
    'projectId': projectId,
    'titleLocked': titleLocked,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    // Written only when set, so a live chat's file is byte-identical to what
    // every build before archiving existed wrote.
    if (archivedAt != null) 'archivedAt': archivedAt!.toIso8601String(),
    // Same rule: absent means "follows the app setting", which is what every
    // chat written before this field existed meant.
    if (approval != null) 'approval': approval!.name,
    // Written only when set, like the two above, so an unpinned chat's file is
    // byte-identical to what every build before pinning existed wrote.
    if (pinned) 'pinned': true,
    if (goal != null) 'goal': goal!.toJson(),
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

/// The longest a derived title runs before it's clipped with an ellipsis.
const int _maxTitleLength = 40;

/// A sidebar title from the first user message — its first line, clipped. Falls
/// back to [kNewConversationTitle] when there's nothing to derive from yet.
String deriveConversationTitle(List<ChatMessage> messages) {
  for (final message in messages) {
    if (message.role != ChatRole.user) continue;
    final line = message.text.trim().split('\n').first.trim();
    if (line.isEmpty) continue;
    return line.length > _maxTitleLength
        ? '${line.substring(0, _maxTitleLength).trimRight()}…'
        : line;
  }
  return kNewConversationTitle;
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
  if (message.sources.isNotEmpty)
    'sources': [for (final s in message.sources) s.toJson()],
  if (message.plan.isNotEmpty)
    'plan': [for (final p in message.plan) p.toJson()],
  if (message.model != null) 'model': message.model,
  // Milliseconds, not a formatted string: the transcript re-renders it in
  // whatever shape the footer wants today, and a saved "8.4s" couldn't.
  if (message.took != null) 'took_ms': message.took!.inMilliseconds,
  if (message.firstToken != null)
    'first_token_ms': message.firstToken!.inMilliseconds,
};

ChatMessage _messageFromJson(Map<String, dynamic> json) {
  final rawMedia = json['media'];
  final rawFiles = json['files'];
  final rawSources = json['sources'];
  final rawPlan = json['plan'];
  return ChatMessage(
    role: json['role'] == ChatRole.assistant.name
        ? ChatRole.assistant
        : ChatRole.user,
    text: json['text'] is String ? json['text'] as String : '',
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
    model: json['model'] is String ? json['model'] as String : null,
    took: json['took_ms'] is num
        ? Duration(milliseconds: (json['took_ms'] as num).toInt())
        : null,
    firstToken: json['first_token_ms'] is num
        ? Duration(milliseconds: (json['first_token_ms'] as num).toInt())
        : null,
  );
}

MediaKind _parseKind(Object? raw) {
  for (final kind in MediaKind.values) {
    if (kind.name == raw) return kind;
  }
  return MediaKind.image;
}

DateTime _parseDate(Object? raw) =>
    raw is String ? DateTime.tryParse(raw) ?? _epoch : _epoch;

/// Like [_parseDate] but keeps null as null instead of falling back to the
/// epoch. Archiving is decided by *whether* this date is there, so the epoch
/// fallback would read every chat that has never been archived as archived in
/// 1970 and empty the sidebar on first launch.
DateTime? _parseNullableDate(Object? raw) =>
    raw is String ? DateTime.tryParse(raw) : null;

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
