import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/review/logic/numstat_parse.dart';
import 'package:grid_app/features/review/logic/review_file.dart';

import 'git_fixtures.dart';

void main() {
  group('parseNumstat', () {
    test('reads the ordinary shape — added, removed, path', () {
      final counts = parseNumstat(z('2\t1\tmod.txt|0\t1\tdel.txt|'));

      expect(counts['mod.txt'], (added: 2, removed: 1, binary: false));
      expect(counts['del.txt'], (added: 0, removed: 1, binary: false));
    });

    test("keys a rename by where the file is now, not where it was — that's "
        'the path the file list carries', () {
      // A rename's own path field is empty and the two paths follow it.
      final counts = parseNumstat(z('0\t0\t|oldname.txt|newname.txt|'));

      expect(counts.containsKey('oldname.txt'), isFalse);
      expect(counts['newname.txt'], (added: 0, removed: 0, binary: false));
    });

    test('marks a binary file rather than reporting it as nothing changed', () {
      final counts = parseNumstat(z('-\t-\tblob.bin|'));

      expect(counts['blob.bin']?.binary, isTrue);
    });

    test('answers nothing for an unchanged repository', () {
      expect(parseNumstat(''), isEmpty);
    });
  });

  group('withCounts', () {
    test('joins what happened to a file with how much of it changed, and '
        'leaves a file the counts say nothing about alone', () {
      final files = [
        const ReviewFile(path: 'mod.txt', kind: ReviewFileKind.modified),
        const ReviewFile(path: 'new.txt', kind: ReviewFileKind.untracked),
      ];

      final counted = withCounts(files, {
        'mod.txt': (added: 2, removed: 1, binary: false),
      });

      expect(counted.first.added, 2);
      expect(counted.first.removed, 1);
      expect(counted.last.added, 0);
      expect(counted.last.kind, ReviewFileKind.untracked);
    });

    test('totals the whole change set, which is what the header shows', () {
      final files = withCounts(
        [
          const ReviewFile(path: 'a.dart', kind: ReviewFileKind.modified),
          const ReviewFile(path: 'b.dart', kind: ReviewFileKind.modified),
        ],
        {
          'a.dart': (added: 10, removed: 4, binary: false),
          'b.dart': (added: 5, removed: 0, binary: false),
        },
      );

      expect(totalAdded(files), 15);
      expect(totalRemoved(files), 4);
    });
  });

  group('untrackedCount', () {
    test('counts every line of a brand-new file as added — Git knows nothing '
        'about it, so nothing else can', () {
      expect(untrackedCount('one\ntwo\nthree\n').added, 3);
    });

    test('does not invent a last line for the closing newline', () {
      expect(untrackedCount('one\ntwo').added, 2);
      expect(untrackedCount('one\ntwo\n').added, 2);
    });

    test('an empty new file adds nothing', () {
      expect(untrackedCount(''), (added: 0, removed: 0, binary: false));
    });

    test('says binary rather than counting bytes as lines', () {
      expect(untrackedCount(z('PNG||')).binary, isTrue);
    });
  });
}
