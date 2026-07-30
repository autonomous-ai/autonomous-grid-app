import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/presentation/chat_minimap.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';

ChatMessage _user(String text) => ChatMessage(role: ChatRole.user, text: text);
ChatMessage _assistant(String text) =>
    ChatMessage(role: ChatRole.assistant, text: text);

void main() {
  group('minimapMarks', () {
    test('marks only the user turns', () {
      final marks = minimapMarks([
        _user('first question'),
        _assistant('a long reply'),
        _user('second question'),
      ]);

      expect(marks.map((m) => m.text), ['first question', 'second question']);
    });

    test('carries each turn s index in the full transcript, so a click '
        'scrolls to the right message', () {
      final marks = minimapMarks([
        _assistant('greeting'),
        _user('question'),
        _assistant('reply'),
        _user('follow-up'),
      ]);

      expect(marks.map((m) => m.index), [1, 3]);
    });

    test('skips a user turn with no text — an attachment-only message has '
        'nothing to preview', () {
      final marks = minimapMarks([_user('   '), _user('real question')]);

      expect(marks.map((m) => m.text), ['real question']);
    });

    test('is empty for a transcript with no user turns', () {
      expect(minimapMarks([_assistant('hello')]), isEmpty);
      expect(minimapMarks([]), isEmpty);
    });
  });

  group('minimapMarks previews', () {
    test('pairs each question with the reply it drew', () {
      final marks = minimapMarks([
        _user('first'),
        _assistant('answer to first'),
        _user('second'),
        _assistant('answer to second'),
      ]);

      expect(marks.map((m) => m.reply), [
        'answer to first',
        'answer to second',
      ]);
    });

    test('leaves the reply null when nothing has answered yet', () {
      final marks = minimapMarks([_user('unanswered')]);

      expect(marks.single.reply, isNull);
    });

    test('leaves the reply null when the user asked twice in a row — the '
        'second question is not an answer to the first', () {
      final marks = minimapMarks([_user('first'), _user('second')]);

      expect(marks.first.reply, isNull);
    });

    test('clips a long question to 100 characters with an ellipsis', () {
      final marks = minimapMarks([_user('x' * 250)]);

      expect(marks.single.text.length, 101); // 100 chars + the ellipsis
      expect(marks.single.text, endsWith('…'));
    });

    test('clips a long reply to 100 characters with an ellipsis', () {
      final marks = minimapMarks([_user('q'), _assistant('y' * 250)]);

      expect(marks.single.reply!.length, 101);
      expect(marks.single.reply, endsWith('…'));
    });

    test(
      'clips a reply far longer than the preview without reading all of '
      'it — a real answer runs to kilobytes and only 100 chars are shown',
      () {
        final marks = minimapMarks([_user('q'), _assistant('z' * 12000)]);

        expect(marks.single.reply!.length, 101);
        expect(marks.single.reply, endsWith('…'));
      },
    );

    test('still marks a long message as clipped when collapsing its '
        'whitespace leaves a short line', () {
      // Only the head of a message is normalised, so a line that comes out
      // short must not read as complete when there was more text behind it.
      final marks = minimapMarks([_user('word${' ' * 4000}tail')]);

      expect(marks.single.text, endsWith('…'));
      expect(marks.single.text, startsWith('word'));
    });

    test('leaves text shorter than the limit unclipped', () {
      final marks = minimapMarks([_user('short one'), _assistant('brief')]);

      expect(marks.single.text, 'short one');
      expect(marks.single.reply, 'brief');
    });

    test('flattens newlines — a markdown reply would otherwise spend the '
        'preview s lines on blanks and bullets', () {
      final marks = minimapMarks([
        _user('q'),
        _assistant('Steps:\n\n- first\n- second'),
      ]);

      expect(marks.single.reply, 'Steps: - first - second');
    });
  });

  group('currentMarkIndex', () {
    // Two questions with a reply each: marks land on messages 0 and 2.
    final marks = minimapMarks([
      _user('first'),
      _assistant('answer'),
      _user('second'),
      _assistant('answer'),
    ]);

    test('marks the question itself when it is the message on screen', () {
      expect(currentMarkIndex(marks, 0), 0);
      expect(currentMarkIndex(marks, 2), 1);
    });

    test('keeps the question lit while its reply is on screen — the reply has '
        'no tick of its own', () {
      expect(currentMarkIndex(marks, 1), 0);
      expect(currentMarkIndex(marks, 3), 1);
    });

    test('marks nothing before the transcript has been measured', () {
      expect(currentMarkIndex(marks, null), isNull);
    });

    test('marks nothing while the messages above the first question are on '
        'screen', () {
      final leading = minimapMarks([_assistant('greeting'), _user('question')]);

      expect(currentMarkIndex(leading, 0), isNull);
      expect(currentMarkIndex(leading, 1), 0);
    });

    test('has nothing to mark on an empty rail', () {
      expect(currentMarkIndex([], 3), isNull);
    });
  });
}
