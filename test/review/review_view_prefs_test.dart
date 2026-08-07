import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/review/logic/review_argv.dart';
import 'package:grid_app/features/review/logic/review_file.dart';
import 'package:grid_app/features/review/logic/review_scope.dart';
import 'package:grid_app/features/review/logic/review_view_prefs.dart';

void main() {
  group('hunkIsOpen', () {
    test('sections are open until the menu folds them', () {
      expect(
        hunkIsOpen(collapsedAll: false, exceptions: const {}, index: 0),
        isTrue,
      );
      expect(
        hunkIsOpen(collapsedAll: true, exceptions: const {}, index: 0),
        isFalse,
      );
    });

    test('a section opened by hand after "collapse all" stays open, and the '
        'rest stay folded — one flag with exceptions, not a flag per '
        'section', () {
      expect(
        hunkIsOpen(collapsedAll: true, exceptions: const {2}, index: 2),
        isTrue,
      );
      expect(
        hunkIsOpen(collapsedAll: true, exceptions: const {2}, index: 3),
        isFalse,
      );
    });

    test('and the same exception folds one section while the rest are open, '
        'so the fold works both ways', () {
      expect(
        hunkIsOpen(collapsedAll: false, exceptions: const {2}, index: 2),
        isFalse,
      );
    });
  });

  group('fileDiffArgv whitespace', () {
    const file = ReviewFile(path: 'a.dart', kind: ReviewFileKind.modified);

    test('asks Git to ignore it rather than filtering the answer — the point '
        'is to drop the lines, and only Git knows which they are', () {
      final args = fileDiffArgv(
        scope: const UncommittedChanges(),
        file: file,
        nullDevice: '/dev/null',
        ignoreWhitespace: true,
      );

      expect(args, contains('-w'));
    });

    test('a brand-new file is diffed against the null device, and takes the '
        'flag there too', () {
      final args = fileDiffArgv(
        scope: const UncommittedChanges(),
        file: const ReviewFile(path: 'a.dart', kind: ReviewFileKind.untracked),
        nullDevice: '/dev/null',
        ignoreWhitespace: true,
      );

      expect(args, containsAllInOrder(['diff', '--no-index', '-w']));
    });

    test('and is left out entirely when the user has not asked for it, so the '
        'everyday command is the one Git documents', () {
      final args = fileDiffArgv(
        scope: const UncommittedChanges(),
        file: file,
        nullDevice: '/dev/null',
      );

      expect(args, isNot(contains('-w')));
    });
  });

  group('DiffLayout', () {
    test('the switch names the click, not the state — a one-button switch '
        'whose icon flips is otherwise a guess', () {
      expect(DiffLayout.unified.switchLabel, 'Switch to side-by-side diff');
      expect(DiffLayout.split.switchLabel, 'Switch to unified diff');
      expect(DiffLayout.unified.other, DiffLayout.split);
    });
  });

  test('folding everything drops the exceptions collected before it, or the '
      'button would stop meaning what it says', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final hunks = container.read(reviewOpenHunksProvider('a.dart').notifier);
    hunks.toggle(2);
    expect(container.read(reviewOpenHunksProvider('a.dart')), {2});

    container.read(diffViewPrefsProvider.notifier).toggleCollapsed();

    expect(container.read(reviewOpenHunksProvider('a.dart')), isEmpty);
  });
}
