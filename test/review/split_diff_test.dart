import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/review/logic/split_diff.dart';
import 'package:grid_app/features/review/logic/unified_diff.dart';

DiffRow context(String text, int line) => DiffRow(
  kind: DiffRowKind.context,
  oldLine: line,
  newLine: line,
  text: text,
);

DiffRow removed(String text, int line) => DiffRow(
  kind: DiffRowKind.removed,
  oldLine: line,
  newLine: null,
  text: text,
);

DiffRow added(String text, int line) =>
    DiffRow(kind: DiffRowKind.added, oldLine: null, newLine: line, text: text);

void main() {
  test('a rewritten line stands opposite the line it replaced, which is what '
      'two columns are for', () {
    final rows = pairRows([
      removed('final x = 1;', 3),
      added('final x = 2;', 3),
    ]);

    expect(rows.length, 1);
    expect(rows.single.before?.text, 'final x = 1;');
    expect(rows.single.after?.text, 'final x = 2;');
  });

  test('a run of removals pairs in order with the run of additions after it, '
      'so a three-line rewrite reads as three changes and not six', () {
    final rows = pairRows([
      removed('a', 1),
      removed('b', 2),
      added('A', 1),
      added('B', 2),
    ]);

    expect(rows.map((r) => '${r.before?.text}→${r.after?.text}'), [
      'a→A',
      'b→B',
    ]);
  });

  test('a longer run leaves the other side empty rather than sliding the next '
      'pair out of step', () {
    final rows = pairRows([removed('a', 1), added('A', 1), added('B', 2)]);

    expect(rows.length, 2);
    expect(rows[1].before, isNull);
    expect(rows[1].after?.text, 'B');
  });

  test('a context line carries itself on both sides — that is what keeps the '
      'columns from drifting apart', () {
    final rows = pairRows([context('kept();', 7)]);

    expect(rows.single.before?.text, 'kept();');
    expect(rows.single.after?.text, 'kept();');
  });

  test("Git's own aside belongs to neither column", () {
    final rows = pairRows([
      const DiffRow(
        kind: DiffRowKind.note,
        oldLine: null,
        newLine: null,
        text: r'\ No newline at end of file',
      ),
    ]);

    expect(rows.single.note, isNotNull);
    expect(rows.single.before, isNull);
    expect(rows.single.after, isNull);
  });

  test('an addition with nothing removed before it sits alone on the right, '
      'where a new line belongs', () {
    final rows = pairRows([context('a', 1), added('new();', 2)]);

    expect(rows[1].before, isNull);
    expect(rows[1].after?.text, 'new();');
  });

  test('a comment on a row points at the new file when there is one, and at '
      'the old file when the line only exists there', () {
    final pair = pairRows([removed('gone();', 4)]).single;
    final both = pairRows([context('kept();', 4)]).single;

    expect(pair.anchorRow?.oldLine, 4);
    expect(both.anchorRow?.newLine, 4);
  });
}
