import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_prompt.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';

ChatFile _file({String? text, bool truncated = false}) => ChatFile(
  path: '/Users/me/Documents/report.docx',
  name: 'report.docx',
  sizeBytes: 18432,
  text: text,
  truncated: truncated,
);

void main() {
  group('what the model is sent', () {
    test('carries the file’s text, so a model with no filesystem can read '
        'the attachment', () {
      final turn = ChatMessage(
        role: ChatRole.user,
        text: 'Summarise this.',
        files: [_file(text: 'Revenue was up 12%.')],
      );

      final sent = messageForModel(turn);

      expect(sent, contains('Summarise this.'));
      expect(sent, contains('Revenue was up 12%.'));
      // The path travels with it: an agent asked to edit the file needs the
      // original, not the copy of its text.
      expect(sent, contains('/Users/me/Documents/report.docx'));
    });

    test('says plainly when the app could not read the file, instead of '
        'sending an empty document', () {
      final turn = ChatMessage(
        role: ChatRole.user,
        text: 'What does this say?',
        files: [_file()],
      );

      final sent = messageForModel(turn);

      expect(sent, contains('could not read'));
      expect(sent, contains('/Users/me/Documents/report.docx'));
    });

    test('flags a file that was cut short, so an agent knows to open the '
        'rest itself', () {
      final turn = ChatMessage(
        role: ChatRole.user,
        files: [_file(text: 'Page one…', truncated: true)],
      );

      expect(messageForModel(turn), contains('cut short'));
    });

    test('a turn with no files is sent exactly as it was typed', () {
      const turn = ChatMessage(role: ChatRole.user, text: 'Hello');

      expect(messageForModel(turn), 'Hello');
    });
  });

  group('the agent prompt', () {
    test('includes the attachment, so the agent answers about the file '
        'rather than about an empty question', () {
      final prompt = buildAgentPrompt([
        ChatMessage(
          role: ChatRole.user,
          text: 'Summarise this.',
          files: [_file(text: 'Revenue was up 12%.')],
        ),
      ]);

      expect(prompt, contains('Revenue was up 12%.'));
    });
  });

  group('a saved conversation', () {
    test('keeps the text that was actually sent, so reopening the chat shows '
        'the document the reply was about', () {
      final saved = Conversation(
        id: 'c1',
        title: 'Report',
        model: 'qwen/qwen3.6-27b',
        createdAt: DateTime(2026, 8, 6),
        updatedAt: DateTime(2026, 8, 6),
        messages: [
          ChatMessage(
            role: ChatRole.user,
            text: 'Summarise this.',
            files: [_file(text: 'Revenue was up 12%.', truncated: true)],
          ),
        ],
      );

      final reopened = Conversation.fromJson(saved.toJson());

      final file = reopened.messages.single.files.single;
      expect(file.name, 'report.docx');
      expect(file.path, '/Users/me/Documents/report.docx');
      expect(file.sizeBytes, 18432);
      expect(file.text, 'Revenue was up 12%.');
      expect(file.truncated, isTrue);
    });

    test('a transcript written before files existed still opens', () {
      final legacy = {
        'id': 'c1',
        'title': 'Old chat',
        'created_at': DateTime(2026, 1, 1).toIso8601String(),
        'updated_at': DateTime(2026, 1, 1).toIso8601String(),
        'messages': [
          {'role': 'user', 'text': 'Hello'},
        ],
      };

      final opened = Conversation.fromJson(legacy);

      expect(opened.messages.single.files, isEmpty);
    });
  });
}
