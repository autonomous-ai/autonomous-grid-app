import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/review/logic/diff_excerpt.dart';
import 'package:grid_app/features/review/logic/unified_diff.dart';

/// The diff a user is looking at, as the view flattens it: line numbers on the
/// side each line exists in.
final _rows = [
  const DiffRow(
    kind: DiffRowKind.context,
    text: 'void main() {',
    oldLine: 10,
    newLine: 10,
  ),
  const DiffRow(kind: DiffRowKind.removed, text: '  print(a);', oldLine: 11),
  const DiffRow(kind: DiffRowKind.added, text: '  log(a);', newLine: 11),
  const DiffRow(kind: DiffRowKind.added, text: '  log(b);', newLine: 12),
  const DiffRow(kind: DiffRowKind.context, text: '}', oldLine: 12, newLine: 13),
];

DiffExcerpt? excerpt(String selected, {List<DiffRow>? rows}) => diffExcerptFor(
  path: 'lib/main.dart',
  rows: rows ?? _rows,
  selected: selected,
);

void main() {
  group('locating what was highlighted', () {
    test('names the lines a highlight covers, so the assistant is sent to the '
        'place the user was reading and not to a guess', () {
      final found = excerpt('  log(a);\n  log(b);')!;

      expect(found.startLine, 11);
      expect(found.endLine, 12);
      expect(found.text, '  log(a);\n  log(b);');
    });

    test('a highlight that stops mid-line keeps exactly the characters that '
        'were under the cursor', () {
      final found = excerpt('log(a);\n  log')!;

      expect(found.text, 'log(a);\n  log');
      expect(found.startLine, 11);
      expect(found.endLine, 12);
    });

    test('one line reads as one line, not as a range that suggests more was '
        'picked than was', () {
      final found = excerpt('  log(b);')!;

      expect(found.startLine, 12);
      expect(found.endLine, 12);
    });

    test('line breaks that never survived the selection are put back, so the '
        'assistant reads code rather than one run-on line', () {
      // What a plain SelectionArea hands back over a list: the rows glued
      // together with nothing between them.
      final found = excerpt('  log(a);  log(b);')!;

      expect(found.text, '  log(a);\n  log(b);');
      expect(found.endLine, 12);
    });

    test(
      'a deleted line gets no number at all: `main.dart:11` reads as line 11 '
      'of the file on disk, and this line is not in that file',
      () {
        final found = excerpt('  print(a);')!;

        expect(found.text, '  print(a);');
        expect(found.startLine, isNull);
        expect(found.endLine, isNull);
      },
    );

    test('lines that are not one unbroken run of the file come back with no '
        'numbers at all: `10-13` would claim lines nobody selected', () {
      // Across the whole patch, which in the new file skips the deleted line.
      final rows = [
        _rows.first,
        const DiffRow(kind: DiffRowKind.context, text: '  far()', newLine: 40),
      ];
      final found = excerpt('void main() {\n  far()', rows: rows)!;

      expect(found.startLine, isNull);
      expect(found.endLine, isNull);
      // The lines themselves are still exact — only the numbers were a guess.
      expect(found.text, 'void main() {\n  far()');
    });

    test('a highlight this list cannot account for still becomes an excerpt, '
        'so the side-by-side view is not left with a dead button', () {
      final found = excerpt('something from another column')!;

      expect(found.text, 'something from another column');
      expect(found.startLine, isNull);
    });

    test('an empty line inside a highlight is passed through rather than '
        'breaking the run it sits in', () {
      final rows = [
        const DiffRow(kind: DiffRowKind.added, text: 'a', newLine: 1),
        const DiffRow(kind: DiffRowKind.added, text: '', newLine: 2),
        const DiffRow(kind: DiffRowKind.added, text: 'b', newLine: 3),
      ];
      final found = excerpt('a\n\nb', rows: rows)!;

      expect(found.startLine, 1);
      expect(found.endLine, 3);
    });

    test('a highlight of nothing but whitespace is not an excerpt — the button '
        'must not offer to send a blank', () {
      expect(excerpt('   \n  '), isNull);
      expect(excerpt(''), isNull);
    });
  });
}
