import '../../../infrastructure/cli/agent_event.dart';
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

  Conversation copyWith({
    String? title,
    String? model,
    DateTime? updatedAt,
    List<ChatMessage>? messages,
    bool? titleLocked,
  }) => Conversation(
    id: id,
    title: title ?? this.title,
    model: model ?? this.model,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    messages: messages ?? this.messages,
    projectId: projectId,
    titleLocked: titleLocked ?? this.titleLocked,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'model': model,
    'projectId': projectId,
    'titleLocked': titleLocked,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
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
      messages: [
        if (rawMessages is List)
          for (final m in rawMessages)
            if (m is Map<String, dynamic>) _messageFromJson(m),
      ],
    );
  }
}

/// The placeholder title before a conversation has any user text.
const String kNewConversationTitle = 'New chat';

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

/// A labelled bucket of conversations for the sidebar (Today / Yesterday / …).
class ConversationGroup {
  const ConversationGroup(this.label, this.conversations);
  final String label;
  final List<Conversation> conversations;
}

/// Buckets [conversations] (already newest-first) by how recently each was last
/// updated, relative to [now] — the Ollama-style history grouping. Empty
/// buckets are dropped, so the sidebar only shows headers that have rows.
List<ConversationGroup> groupConversationsByRecency(
  List<Conversation> conversations,
  DateTime now,
) {
  final startOfToday = DateTime(now.year, now.month, now.day);
  final today = <Conversation>[];
  final yesterday = <Conversation>[];
  final week = <Conversation>[];
  final older = <Conversation>[];
  for (final c in conversations) {
    final d = c.updatedAt;
    if (!d.isBefore(startOfToday)) {
      today.add(c);
    } else if (!d.isBefore(startOfToday.subtract(const Duration(days: 1)))) {
      yesterday.add(c);
    } else if (!d.isBefore(startOfToday.subtract(const Duration(days: 7)))) {
      week.add(c);
    } else {
      older.add(c);
    }
  }
  return [
    if (today.isNotEmpty) ConversationGroup('Today', today),
    if (yesterday.isNotEmpty) ConversationGroup('Yesterday', yesterday),
    if (week.isNotEmpty) ConversationGroup('Previous 7 days', week),
    if (older.isNotEmpty) ConversationGroup('Older', older),
  ];
}

Map<String, dynamic> _messageToJson(ChatMessage message) => {
  'role': message.role.name,
  'text': message.text,
  'media': [
    for (final m in message.media) {'path': m.path, 'kind': m.kind.name},
  ],
  if (message.sources.isNotEmpty)
    'sources': [for (final s in message.sources) s.toJson()],
  if (message.plan.isNotEmpty)
    'plan': [for (final p in message.plan) p.toJson()],
};

ChatMessage _messageFromJson(Map<String, dynamic> json) {
  final rawMedia = json['media'];
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

final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);
