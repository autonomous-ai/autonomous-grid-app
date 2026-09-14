import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/messaging/logic/telegram/telegram_markup.dart';
import 'package:grid_app/features/messaging/logic/telegram/telegram_stream.dart';

void main() {
  group('an answer in Telegram HTML', () {
    test('bold, italic and inline code keep their meaning', () {
      expect(telegramHtml('**a** _b_ `c`'), '<b>a</b> <i>b</i> <code>c</code>');
    });

    test('brackets and ampersands are escaped, so an answer about HTML cannot '
        'break the message Telegram parses', () {
      expect(telegramHtml('a <b> & c'), 'a &lt;b&gt; &amp; c');
    });

    test('a fenced block keeps its language for highlighting', () {
      expect(
        telegramHtml('```dart\nvoid main() {}\n```'),
        '<pre><code class="language-dart">void main() {}</code></pre>',
      );
    });

    test(
      'lists become bullet and numbered lines, since Telegram has neither',
      () {
        expect(telegramHtml('- a\n- b'), '• a\n• b');
        expect(telegramHtml('3. x\n4. y'), '3. x\n4. y');
      },
    );

    test('headings become bold lines', () {
      expect(telegramHtml('# Title'), '<b>Title</b>');
    });

    test('only web, mail and Telegram links stay tappable', () {
      expect(telegramHtml('[x](https://a.b)'), '<a href="https://a.b">x</a>');
      expect(telegramHtml('[x](javascript:alert(1))'), 'x');
    });

    test('the plain fallback reads back the same words', () {
      expect(telegramPlainText('<b>a</b> &lt;b&gt; &amp;'), 'a <b> &');
    });
  });

  group('splitting a long answer', () {
    test('a code block is never cut at its own blank lines', () {
      expect(markdownBlocks('para\n\n```\na\n\nb\n```\n\nend'), [
        'para',
        '```\na\n\nb\n```',
        'end',
      ]);
    });

    test('every message fits the limit, and a long answer takes several', () {
      final answer = List.filled(50, 'word ' * 30).join('\n\n');

      final chunks = telegramChunks(answer, limit: 500);

      expect(chunks.length, greaterThan(1));
      expect(chunks.every((chunk) => chunk.text.length <= 500), isTrue);
    });

    test('one block too long for a message goes as plain pieces, whole', () {
      final chunks = telegramChunks('x' * 1200, limit: 500);

      expect(chunks.every((chunk) => !chunk.html), isTrue);
      expect(chunks.map((chunk) => chunk.text).join(), 'x' * 1200);
    });

    test('a short answer is one message', () {
      expect(telegramChunks('hi'), [(text: 'hi', html: true)]);
    });
  });

  group('drawing an answer as it arrives', () {
    const first = (text: 'one', html: true);
    const second = (text: 'two', html: true);

    test('a message already showing those words is left alone, so a long '
        'answer costs one edit a flush rather than a screenful', () {
      expect(telegramStreamEdits(const ['one'], const [first]), isEmpty);
    });

    test('the message that grew is edited, and the part past it is sent', () {
      final edits = telegramStreamEdits(const ['on'], const [first, second]);

      expect(
        [for (final edit in edits) (edit.index, edit.fresh)],
        [(0, false), (1, true)],
      );
    });

    test('nothing on the phone yet means every message is a new one', () {
      expect(
        telegramStreamEdits(const [], const [first, second]),
        hasLength(2),
      );
    });
  });
}
