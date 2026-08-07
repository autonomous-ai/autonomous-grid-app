import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';

ChatContext _terminal({bool truncated = false}) => ChatContext(
  label: 'Terminal',
  detail: '/Users/me/Musiky',
  text: '\$ flutter run\nNo devices found.',
  truncated: truncated,
);

void main() {
  group('what the model is sent', () {
    test('carries the terminal, so an agent can answer about the error the '
        'user is looking at', () {
      final turn = ChatMessage(
        role: ChatRole.user,
        text: 'Why did this fail?',
        contexts: [_terminal()],
      );

      final sent = messageForModel(turn);

      expect(sent, contains('Why did this fail?'));
      expect(sent, contains('No devices found.'));
      // The folder travels with it: the same command fails differently in
      // another project, and an agent with a shell needs to know where it was.
      expect(sent, contains('/Users/me/Musiky'));
    });

    test('says when only the end of the terminal is there, so an agent asks '
        'for the rest instead of answering from half a log', () {
      final turn = ChatMessage(
        role: ChatRole.user,
        contexts: [_terminal(truncated: true)],
      );

      expect(messageForModel(turn), contains('more above it'));
    });

    test('puts the files first: a document was picked, a terminal was merely '
        'open', () {
      final turn = ChatMessage(
        role: ChatRole.user,
        text: 'Compare these.',
        files: const [
          ChatFile(
            path: '/Users/me/notes.txt',
            name: 'notes.txt',
            sizeBytes: 12,
            text: 'the note',
          ),
        ],
        contexts: [_terminal()],
      );

      final sent = messageForModel(turn);

      expect(sent.indexOf('the note'), lessThan(sent.indexOf('flutter run')));
    });

    test('a turn with nothing on screen is sent exactly as it was typed', () {
      const turn = ChatMessage(role: ChatRole.user, text: 'Hello');

      expect(messageForModel(turn), 'Hello');
    });
  });

  group('a saved conversation', () {
    test('keeps the terminal that was sent, because the real one has scrolled '
        'on by the time the chat is reopened', () {
      final saved = Conversation(
        id: 'c1',
        title: 'Musiky',
        model: 'qwen/qwen3.6-27b',
        createdAt: DateTime(2026, 8, 7),
        updatedAt: DateTime(2026, 8, 7),
        messages: [
          ChatMessage(
            role: ChatRole.user,
            text: 'Why did this fail?',
            contexts: [_terminal(truncated: true)],
          ),
        ],
      );

      final context = Conversation.fromJson(
        saved.toJson(),
      ).messages.single.contexts.single;

      expect(context.label, 'Terminal');
      expect(context.detail, '/Users/me/Musiky');
      expect(context.text, contains('No devices found.'));
      expect(context.truncated, isTrue);
    });

    test('a transcript written before terminals rode along still opens', () {
      final legacy = {
        'id': 'c1',
        'title': 'Old chat',
        'created_at': DateTime(2026, 1, 1).toIso8601String(),
        'updated_at': DateTime(2026, 1, 1).toIso8601String(),
        'messages': [
          {'role': 'user', 'text': 'Hello'},
        ],
      };

      expect(Conversation.fromJson(legacy).messages.single.contexts, isEmpty);
    });
  });
}
