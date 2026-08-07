import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/review/logic/review_comment.dart';
import 'package:grid_app/features/review/logic/unified_diff.dart';

ReviewComment comment(String path, int line, String text, {String code = ''}) =>
    ReviewComment(
      path: path,
      side: DiffSide.after,
      line: line,
      text: text,
      code: code,
    );

void main() {
  group('commentAnchorFor', () {
    test('a removed line is pointed at in the file it still exists in — the '
        'old one, since the new file has no such line', () {
      const row = DiffRow(
        kind: DiffRowKind.removed,
        oldLine: 12,
        newLine: null,
        text: 'gone();',
      );

      expect(commentAnchorFor(row), (side: DiffSide.before, line: 12));
    });

    test('a line that survives is quoted by the number it has now, which is '
        'the one the assistant will be reading', () {
      const row = DiffRow(
        kind: DiffRowKind.context,
        oldLine: 12,
        newLine: 30,
        text: 'kept();',
      );

      expect(commentAnchorFor(row), (side: DiffSide.after, line: 30));
    });

    test("Git's own aside about a file carries no line to point at, so it "
        'offers no comment rather than one on a number it invented', () {
      const row = DiffRow(
        kind: DiffRowKind.note,
        oldLine: null,
        newLine: null,
        text: r'\ No newline at end of file',
      );

      expect(commentAnchorFor(row), isNull);
    });
  });

  group('commentsPrompt', () {
    test('quotes the line beside its number, because the assistant reads the '
        'file after its own edits have moved everything below it', () {
      final prompt = commentsPrompt([
        comment('lib/a.dart', 32, 'Rename this', code: 'final x = 1;'),
      ]);

      expect(prompt, contains('lib/a.dart:32'));
      expect(prompt, contains('`final x = 1;`'));
      expect(prompt, contains('Rename this'));
      expect(prompt, contains('Read each file around the line quoted'));
    });

    test('counts what it is carrying, so the message reads as one request '
        'rather than a list of unrelated asks', () {
      final prompt = commentsPrompt([
        comment('lib/a.dart', 1, 'One'),
        comment('lib/b.dart', 2, 'Two'),
      ]);

      expect(prompt, startsWith('I have left 2 comments'));
    });

    test('nothing to send is an empty message, not a request with no body', () {
      expect(commentsPrompt(const []), isEmpty);
    });
  });

  group('commentsForFile', () {
    test('keeps only the file being drawn — a diff shows one file, and the '
        'others are still waiting on their own', () {
      final all = [
        comment('lib/a.dart', 1, 'One'),
        comment('lib/b.dart', 2, 'Two'),
      ];

      final mine = commentsForFile(all, 'lib/a.dart');

      expect(mine.length, 1);
      expect(mine.single.path, 'lib/a.dart');
    });
  });

  group('ReviewComment', () {
    test('names its line the way a diff does, so "line 32" is never two '
        'different lines', () {
      expect(comment('a', 32, 'x').anchor, 'R32');
      expect(
        const ReviewComment(
          path: 'a',
          side: DiffSide.before,
          line: 32,
          text: 'x',
        ).anchor,
        'L32',
      );
    });

    test('two remarks are on the same line only when the file, the side and '
        'the number all agree', () {
      final mine = comment('lib/a.dart', 32, 'One');

      expect(mine.sameLineAs(comment('lib/a.dart', 32, 'Two')), isTrue);
      expect(mine.sameLineAs(comment('lib/b.dart', 32, 'Two')), isFalse);
      expect(
        mine.sameLineAs(
          const ReviewComment(
            path: 'lib/a.dart',
            side: DiffSide.before,
            line: 32,
            text: 'Two',
          ),
        ),
        isFalse,
      );
    });
  });
}
