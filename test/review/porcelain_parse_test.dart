import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/review/logic/porcelain_parse.dart';
import 'package:grid_app/features/review/logic/review_file.dart';

import 'git_fixtures.dart';

/// Every fixture here is real output captured from `git status --porcelain=v2
/// -z --untracked-files=all` and `git diff --name-status -M -z` (Git 2.33) in a
/// repository staged to hold one of each kind of change — hashes shortened.
/// Hand-written samples would only prove the parser agrees with our idea of the
/// format.
void main() {
  group('parsePorcelainV2', () {
    test('tells a staged change from one only in the working tree, because '
        'only the staged half would end up in a commit', () {
      final files = parsePorcelainV2(
        z(
          '1 A. N... 000000 100644 100644 0000 91d5 staged_new.txt|'
          '1 .M N... 100644 100644 100644 422c 422c mod.txt|',
        ),
      );

      final staged = files.firstWhere((f) => f.path == 'staged_new.txt');
      final worktree = files.firstWhere((f) => f.path == 'mod.txt');
      expect(staged.staged, isTrue);
      expect(staged.kind, ReviewFileKind.added);
      expect(worktree.staged, isFalse);
      expect(worktree.kind, ReviewFileKind.modified);
    });

    test('reads a rename as one moved file, not an add and a delete — its '
        'original path is a field of its own after the record', () {
      final files = parsePorcelainV2(
        z(
          '2 R. N... 100644 100644 100644 0f41 0f41 R100 newname.txt|'
          'oldname.txt|'
          '1 .D N... 100644 100644 000000 286c 286c del.txt|',
        ),
      );

      expect(files.map((f) => f.path), ['del.txt', 'newname.txt']);
      final renamed = files.firstWhere((f) => f.path == 'newname.txt');
      expect(renamed.kind, ReviewFileKind.renamed);
      expect(renamed.oldPath, 'oldname.txt');
      expect(
        files.firstWhere((f) => f.path == 'del.txt').kind,
        ReviewFileKind.deleted,
      );
    });

    test('keeps an untracked file apart from an added one: nothing commits it '
        'until the user stages it', () {
      final files = parsePorcelainV2(z('? untracked.txt|'));

      expect(files.single.kind, ReviewFileKind.untracked);
      expect(files.single.staged, isFalse);
    });

    test('keeps a path that contains spaces whole', () {
      final files = parsePorcelainV2(
        z('1 .M N... 100644 100644 100644 422c 422c my notes/to do.txt|'),
      );

      expect(files.single.path, 'my notes/to do.txt');
      expect(files.single.folder, 'my notes');
      expect(files.single.name, 'to do.txt');
    });

    test('reports a half-merged file as conflicted rather than modified, so '
        'the screen never offers to commit an unresolved merge', () {
      final files = parsePorcelainV2(
        z(
          '1 .M N... 100644 100644 100644 422c 422c mod.txt|'
          'u UU N... 100644 100644 100644 100644 1111 2222 3333 both.txt|',
        ),
      );

      expect(
        files.firstWhere((f) => f.path == 'both.txt').kind,
        ReviewFileKind.conflicted,
      );
    });

    test('skips records it does not know instead of blanking the screen', () {
      final files = parsePorcelainV2(
        z(
          '# branch.oid 1111|'
          '! ignored.txt|'
          '1 .M N... 100644 100644 100644 422c 422c mod.txt|'
          'x nonsense|',
        ),
      );

      expect(files.map((f) => f.path), ['mod.txt']);
    });

    test('answers nothing for a clean repository', () {
      expect(parsePorcelainV2(''), isEmpty);
    });
  });

  group('parseNameStatus', () {
    test('reads a branch comparison, where a rename carries both of its paths '
        'and everything in it is already committed', () {
      final files = parseNameStatus(
        z(
          'A|blob.bin|'
          'D|del.txt|'
          'M|mod.txt|'
          'R100|oldname.txt|newname.txt|'
          'A|staged_new.txt|',
        ),
      );

      expect(files.map((f) => f.path), [
        'blob.bin',
        'del.txt',
        'mod.txt',
        'newname.txt',
        'staged_new.txt',
      ]);
      final renamed = files.firstWhere((f) => f.path == 'newname.txt');
      expect(renamed.kind, ReviewFileKind.renamed);
      expect(renamed.oldPath, 'oldname.txt');
      expect(files.every((f) => f.staged), isTrue);
    });

    test('treats a copy as a new file, since the original is still there', () {
      final files = parseNameStatus(z('C75|from.txt|to.txt|'));

      expect(files.single.path, 'to.txt');
      expect(files.single.kind, ReviewFileKind.added);
      expect(files.single.oldPath, isNull);
    });
  });
}
