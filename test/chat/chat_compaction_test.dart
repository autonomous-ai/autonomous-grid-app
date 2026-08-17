import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/commands/chat_compaction.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';

ChatMessage _user(String text) => ChatMessage(role: ChatRole.user, text: text);
ChatMessage _bot(String text) =>
    ChatMessage(role: ChatRole.assistant, text: text);

ChatCompaction _compaction({required int through, String summary = 'notes'}) =>
    ChatCompaction(
      summary: summary,
      through: through,
      at: DateTime.utc(2026, 8, 17),
    );

void main() {
  group('what a turn carries after compacting', () {
    final messages = [_user('one'), _bot('two'), _user('three'), _bot('four')];

    test('an uncompacted chat carries every word of itself', () {
      expect(historyForTurn(messages, null), messages);
    });

    test('the summary stands in for what it covers, and everything said since '
        'is carried as it was said', () {
      final carried = historyForTurn(messages, _compaction(through: 2));

      expect(carried, hasLength(3));
      expect(carried.first.role, ChatRole.user);
      expect(carried.first.text, contains('notes'));
      expect(carried[1].text, 'three');
      expect(carried[2].text, 'four');
    });

    test('a compaction covering the whole chat carries the summary alone', () {
      expect(historyForTurn(messages, _compaction(through: 4)), hasLength(1));
    });

    test('a compaction longer than the chat still covers all of it — a '
        'restored file must not silently undo the compaction', () {
      expect(historyForTurn(messages, _compaction(through: 9)), hasLength(1));
    });
  });

  group('the summary survives a restart', () {
    test('a written compaction reads back as itself', () {
      final written = _compaction(through: 3, summary: 'what we decided');
      final read = ChatCompaction.fromJson(written.toJson());

      expect(read?.summary, 'what we decided');
      expect(read?.through, 3);
      expect(read?.at, written.at);
    });

    test(
      'half-written or foreign JSON reads as no compaction, so the chat '
      'opens carrying its whole history — costing context, never content',
      () {
        expect(ChatCompaction.fromJson(null), isNull);
        expect(ChatCompaction.fromJson({'summary': '', 'through': 2}), isNull);
        expect(ChatCompaction.fromJson({'summary': 'x', 'through': 0}), isNull);
        expect(
          ChatCompaction.fromJson({'summary': 'x', 'through': 2, 'at': 'nope'}),
          isNull,
        );
      },
    );
  });

  group('what the summarizer is asked', () {
    test('the request carries the transcript with who said what, and skips '
        'the picture-only turns that would read as blanks', () {
      final asked = buildCompactMessages(
        messages: [_user('fix the parser'), _bot(''), _bot('done')],
        focus: '',
      );

      expect(asked, hasLength(2));
      expect(asked.last['content'], contains('User: fix the parser'));
      expect(asked.last['content'], contains('Assistant: done'));
      // The empty turn left no "Assistant:" line of its own.
      expect('Assistant:'.allMatches(asked.last['content']!).length, 1);
    });

    test("the user's own words steer the summary when they gave any", () {
      final asked = buildCompactMessages(
        messages: [_user('hi')],
        focus: 'only the API decisions',
      );

      expect(asked.last['content'], contains('only the API decisions'));
    });

    test('no focus adds no instruction to follow', () {
      final asked = buildCompactMessages(messages: [_user('hi')], focus: '  ');

      expect(asked.last['content'], isNot(contains('focus on')));
    });
  });
}
