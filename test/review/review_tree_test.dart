import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/review/logic/review_file.dart';
import 'package:grid_app/features/review/logic/review_tree.dart';

void main() {
  const files = [
    ReviewFile(path: 'README.md', kind: ReviewFileKind.modified),
    ReviewFile(path: 'lib/a.dart', kind: ReviewFileKind.modified),
    ReviewFile(path: 'lib/b.dart', kind: ReviewFileKind.added),
    ReviewFile(
      path: 'lib/new/name.dart',
      oldPath: 'lib/old/name.dart',
      kind: ReviewFileKind.renamed,
    ),
  ];

  group('groupByFolder', () {
    test('gathers a folder\'s files under one heading, so forty rows that all '
        'start with lib/features/ stop reading as one wall of text', () {
      final groups = groupByFolder(files);

      expect(groups.map((g) => g.folder), ['', 'lib', 'lib/new']);
      expect(groups[1].files.map((f) => f.name), ['a.dart', 'b.dart']);
    });

    test('the repository root says what it is rather than showing a blank '
        'heading', () {
      expect(groupByFolder(files).first.label, 'Top level');
    });
  });

  group('filterFiles', () {
    test('matches on the whole path, which is the only way to tell two files '
        'with the same name apart', () {
      expect(filterFiles(files, 'lib/new').map((f) => f.path), [
        'lib/new/name.dart',
      ]);
    });

    test('finds a renamed file by the name it used to have, because that is '
        'the name the user remembers', () {
      expect(filterFiles(files, 'old/name').single.path, 'lib/new/name.dart');
    });

    test('an empty query changes nothing', () {
      expect(filterFiles(files, '   ').length, files.length);
    });
  });
}
