import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';
import 'package:grid_app/features/playground/logic/message_media.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';

Conversation _conversation({
  String id = 'c1',
  String title = 'Hello',
  String model = 'qwen',
  DateTime? updatedAt,
  List<ChatMessage> messages = const [],
  String? projectId,
  DateTime? archivedAt,
}) {
  final at = updatedAt ?? DateTime(2026, 1, 1, 12);
  return Conversation(
    id: id,
    title: title,
    model: model,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: at,
    messages: messages,
    projectId: projectId,
    archivedAt: archivedAt,
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

    test('round-trips an agent turn with its web sources', () {
      final original = _conversation(
        messages: [
          const ChatMessage(role: ChatRole.user, text: 'latest flutter news'),
          const ChatMessage(
            role: ChatRole.assistant,
            text: 'Here is what I found.',
            sources: [
              WebSource(title: 'Flutter', url: 'https://flutter.dev'),
              WebSource(title: 'Dart', url: 'https://dart.dev'),
            ],
          ),
        ],
      );

      final restored = Conversation.fromJson(original.toJson());

      final sources = restored.messages.last.sources;
      expect(sources.map((s) => s.url), [
        'https://flutter.dev',
        'https://dart.dev',
      ]);
      // A plain text turn stays sourceless rather than gaining an empty list.
      expect(restored.messages.first.sources, isEmpty);
    });

    test('round-trips the model that answered, so the transcript still names '
        'it after a reload', () {
      final original = _conversation(
        messages: [
          const ChatMessage(role: ChatRole.user, text: 'hi'),
          const ChatMessage(
            role: ChatRole.assistant,
            text: 'Hello!',
            model: 'qwen/qwen3.6-27b',
          ),
        ],
      );

      final restored = Conversation.fromJson(original.toJson());

      expect(restored.messages.last.model, 'qwen/qwen3.6-27b');
      // The user turn carries no model — it isn't an answer.
      expect(restored.messages.first.model, isNull);
    });

    test('round-trips how long the answer took, so a reopened chat still says '
        'which model was slow and which was not', () {
      final original = _conversation(
        messages: [
          const ChatMessage(role: ChatRole.user, text: 'hi'),
          const ChatMessage(
            role: ChatRole.assistant,
            text: 'Hello!',
            model: 'qwen/qwen3.6-27b',
            took: Duration(milliseconds: 8400),
          ),
        ],
      );

      final restored = Conversation.fromJson(original.toJson());

      expect(restored.messages.last.took, const Duration(milliseconds: 8400));
      expect(restored.messages.first.took, isNull);
    });

    test('round-trips when the first word appeared, which is the half of "was '
        'that slow?" the total cannot answer', () {
      final original = _conversation(
        messages: [
          const ChatMessage(
            role: ChatRole.assistant,
            text: 'Hello!',
            model: 'qwen/qwen3.6-27b',
            took: Duration(milliseconds: 8400),
            firstToken: Duration(milliseconds: 1200),
          ),
        ],
      );

      final restored = Conversation.fromJson(original.toJson());

      expect(
        restored.messages.single.firstToken,
        const Duration(milliseconds: 1200),
      );
    });

    test('a chat saved before turns were timed reloads without one, rather '
        'than claiming it was instant', () {
      final json = _conversation(
        messages: [
          const ChatMessage(
            role: ChatRole.assistant,
            text: 'Hello!',
            model: 'qwen',
          ),
        ],
      ).toJson();

      final restored = Conversation.fromJson(json);

      expect(restored.messages.single.took, isNull);
    });

    test(
      'round-trips an agent turn with its to-do plan and each step status',
      () {
        final original = _conversation(
          messages: [
            const ChatMessage(role: ChatRole.user, text: 'refactor the parser'),
            const ChatMessage(
              role: ChatRole.assistant,
              text: 'Done.',
              plan: [
                AgentPlanEntry(
                  content: 'Read the file',
                  status: AgentPlanStatus.done,
                ),
                AgentPlanEntry(
                  content: 'Rewrite it',
                  status: AgentPlanStatus.active,
                ),
                AgentPlanEntry(
                  content: 'Run the tests',
                  status: AgentPlanStatus.pending,
                ),
              ],
            ),
          ],
        );

        final restored = Conversation.fromJson(original.toJson());

        final plan = restored.messages.last.plan;
        expect(plan.map((e) => e.content), [
          'Read the file',
          'Rewrite it',
          'Run the tests',
        ]);
        expect(plan.map((e) => e.status), [
          AgentPlanStatus.done,
          AgentPlanStatus.active,
          AgentPlanStatus.pending,
        ]);
        // A plain text turn stays planless rather than gaining an empty list.
        expect(restored.messages.first.plan, isEmpty);
      },
    );

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

  group('liveConversations', () {
    test('hides the archived chats and keeps the order it was given', () {
      final live = liveConversations([
        _conversation(id: 'a'),
        _conversation(id: 'filed', archivedAt: DateTime(2026, 2, 1)),
        _conversation(id: 'b'),
      ]);

      expect(live.map((c) => c.id), ['a', 'b']);
    });
  });

  group('liveChatCountIn', () {
    test("counts only the project's own chats that are still in the rail", () {
      final all = [
        _conversation(id: 'in-1', projectId: 'p1'),
        _conversation(id: 'in-2', projectId: 'p1'),
        _conversation(id: 'elsewhere', projectId: 'p2'),
        _conversation(id: 'loose'),
        _conversation(
          id: 'filed',
          projectId: 'p1',
          archivedAt: DateTime(2026, 2, 1),
        ),
      ];

      // The number on the card has to match the rows the sidebar shows, so an
      // archived chat must not be counted even though it still holds the
      // project.
      expect(liveChatCountIn(all, 'p1'), 2);
      expect(liveChatCountIn(all, 'p2'), 1);
      expect(liveChatCountIn(all, 'unknown'), 0);
    });
  });

  group('a pinned chat', () {
    Conversation chat(String id, {bool pinned = false, DateTime? at}) =>
        Conversation(
          id: id,
          title: id,
          model: 'm',
          createdAt: DateTime(2026),
          updatedAt: at ?? DateTime(2026),
          pinned: pinned,
        );

    test('leads the working history, so the two chats you keep coming back to '
        'stop sliding down the rail', () {
      final ordered = liveConversations([
        chat('newest', at: DateTime(2026, 8, 5)),
        chat('kept', pinned: true, at: DateTime(2026, 1, 1)),
        chat('older', at: DateTime(2026, 7, 1)),
      ]);

      expect([for (final c in ordered) c.id], ['kept', 'newest', 'older']);
    });

    test('keeps its place within the pinned group — pinning is not a sort', () {
      final ordered = liveConversations([
        chat('a', pinned: true, at: DateTime(2026, 8, 5)),
        chat('b', pinned: true, at: DateTime(2026, 8, 4)),
      ]);

      expect([for (final c in ordered) c.id], ['a', 'b']);
    });

    test('survives a restart, and an unpinned chat writes no field at all', () {
      final pinned = chat('p', pinned: true);
      expect(pinned.toJson()['pinned'], isTrue);
      expect(chat('u').toJson().containsKey('pinned'), isFalse);

      final read = Conversation.fromJson(pinned.toJson());
      expect(read.pinned, isTrue);
      // A file from before pinning existed reads as unpinned rather than
      // throwing.
      expect(Conversation.fromJson(chat('u').toJson()).pinned, isFalse);
    });
  });
}
