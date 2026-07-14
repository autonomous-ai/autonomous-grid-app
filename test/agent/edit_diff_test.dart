import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/edit_diff.dart';

String _render(List<DiffLine> lines) => [
  for (final line in lines)
    '${switch (line.kind) {
      DiffLineKind.added => '+',
      DiffLineKind.removed => '-',
      DiffLineKind.context => ' ',
    }}${line.text}',
].join('\n');

void main() {
  test('a one-line change shows that line, not the whole file', () {
    final diff = buildEditDiff('a\nb\nc\nd\ne\nf\n', 'a\nb\nC\nd\ne\nf\n');

    expect(_render(diff), ' a\n b\n-c\n+C\n d\n e');
  });

  test('a new file is all additions', () {
    final diff = buildEditDiff(null, 'hello\nworld\n');

    expect(diff.map((l) => l.kind), everyElement(DiffLineKind.added));
    expect(_render(diff), '+hello\n+world');
  });

  test('an appended line is not read as a rewrite of the file', () {
    final diff = buildEditDiff('one\ntwo\n', 'one\ntwo\nthree\n');

    expect(_render(diff), ' one\n two\n+three');
  });

  test('the trailing newline is not a phantom changed line', () {
    expect(buildEditDiff('same\n', 'same\n'), isEmpty);
  });

  test('a huge change is cut off, and says so — approving what you cannot read '
      'is not consent', () {
    final huge = List.generate(500, (i) => 'line $i').join('\n');
    final diff = buildEditDiff(null, huge, maxLines: 20);

    expect(diff, hasLength(21));
    expect(diff.last.text, contains('480 more lines'));
  });
}
