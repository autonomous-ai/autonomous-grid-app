import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';
import 'package:grid_app/features/playground/logic/message_media.dart';

Conversation _conversation({
  String id = 'c1',
  String title = 'Hello',
  String model = 'qwen',
  DateTime? updatedAt,
  List<ChatMessage> messages = const [],
}) {
  final at = updatedAt ?? DateTime(2026, 1, 1, 12);
  return Conversation(
    id: id,
    title: title,
    model: model,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: at,
    messages: messages,
  );
}

void main() {
  group('serialization', () {
    test('round-trips text + media through JSON', () {
      final original = _conversation(
        messages: [
          const ChatMessage(role: ChatRole.user, text: 'draw a cat'),
          const ChatMessage(
            role: ChatRole.assistant,
            media: [ChatMedia(path: '/tmp/cat.png', kind: MediaKind.image)],
          ),
        ],
      );

      final restored = Conversation.fromJson(original.toJson());

      expect(restored.id, original.id);
      expect(restored.title, original.title);
      expect(restored.model, original.model);
      expect(restored.createdAt, original.createdAt);
      expect(restored.updatedAt, original.updatedAt);
      expect(restored.messages, hasLength(2));
      expect(restored.messages.first.role, ChatRole.user);
      expect(restored.messages.first.text, 'draw a cat');
      final media = restored.messages.last.media.single;
      expect(media.path, '/tmp/cat.png');
      expect(media.kind, MediaKind.image);
    });

    test('throws when the id is missing so the store can skip the file', () {
      expect(
        () => Conversation.fromJson(const {'title': 'x'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('tolerates a missing messages list', () {
      final restored = Conversation.fromJson(const {'id': 'c9'});
      expect(restored.messages, isEmpty);
      expect(restored.title, kNewConversationTitle);
    });
  });

  group('deriveConversationTitle', () {
    test('uses the first user line, clipped', () {
      final title = deriveConversationTitle([
        const ChatMessage(
          role: ChatRole.user,
          text:
              'Explain quantum tunnelling to me like I am five years old '
              'please',
        ),
      ]);
      expect(title.length, lessThanOrEqualTo(41)); // 40 chars + ellipsis
      expect(title, endsWith('…'));
      expect(title, startsWith('Explain quantum tunnelling'));
    });

    test('skips assistant turns and blank lines', () {
      final title = deriveConversationTitle([
        const ChatMessage(role: ChatRole.assistant, text: 'Hi there'),
        const ChatMessage(role: ChatRole.user, text: '\n  first ask  \n'),
      ]);
      expect(title, 'first ask');
    });

    test('falls back to the placeholder with no user text', () {
      expect(deriveConversationTitle(const []), kNewConversationTitle);
    });
  });

  group('groupConversationsByRecency', () {
    test('buckets by last-updated and drops empty buckets', () {
      final now = DateTime(2026, 7, 8, 10);
      final groups = groupConversationsByRecency([
        _conversation(id: 'today', updatedAt: DateTime(2026, 7, 8, 9)),
        _conversation(id: 'yesterday', updatedAt: DateTime(2026, 7, 7, 23)),
        _conversation(id: 'lastweek', updatedAt: DateTime(2026, 7, 3)),
        _conversation(id: 'ancient', updatedAt: DateTime(2026, 1, 1)),
      ], now);

      expect(groups.map((g) => g.label), [
        'Today',
        'Yesterday',
        'Previous 7 days',
        'Older',
      ]);
      expect(groups.first.conversations.single.id, 'today');
      expect(groups.last.conversations.single.id, 'ancient');
    });

    test('returns nothing for an empty history', () {
      expect(
        groupConversationsByRecency(const [], DateTime(2026, 7, 8)),
        isEmpty,
      );
    });
  });
}
