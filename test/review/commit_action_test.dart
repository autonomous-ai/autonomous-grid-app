import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/review/logic/commit_action.dart';
import 'package:grid_app/features/review/logic/review_argv.dart';
import 'package:grid_app/features/review/logic/review_file.dart';
import 'package:grid_app/features/review/logic/review_scope.dart';
import 'package:grid_app/features/review/logic/review_snapshot.dart';

ReviewFile file(String path, {bool staged = false}) =>
    ReviewFile(path: path, kind: ReviewFileKind.modified, staged: staged);

ReviewSnapshot snapshot({
  ReviewScope scope = const UncommittedChanges(),
  List<ReviewFile> files = const [],
  int ahead = 0,
  bool detached = false,
}) => ReviewSnapshot(
  root: '/repo',
  branch: detached ? 'HEAD' : 'main',
  scope: scope,
  files: files,
  ahead: ahead,
  detached: detached,
);

void main() {
  group('commitActionFor', () {
    test('ticked files make the button a commit — the thing the user came '
        'here to do', () {
      final state = snapshot(files: [file('a.dart', staged: true)]);

      expect(commitActionFor(state), CommitAction.commit);
    });

    test('with changes but nothing ticked the button offers to tick them, '
        'never to sit there greyed out saying "Nothing ticked"', () {
      final state = snapshot(files: [file('a.dart')]);

      expect(commitActionFor(state), CommitAction.commitAll);
      expect(CommitAction.commitAll.label, 'Commit all');
    });

    test('a commit or a branch has nothing to tick, so waiting commits are '
        'what the button offers instead', () {
      final state = snapshot(
        scope: const BranchAgainst('origin/main'),
        files: [file('a.dart')],
        ahead: 2,
      );

      expect(commitActionFor(state), CommitAction.push);
    });

    test('committing outranks pushing: work only in the working tree is what '
        'is at risk, an unpushed commit is already saved', () {
      final state = snapshot(files: [file('a.dart', staged: true)], ahead: 3);

      expect(commitActionFor(state), CommitAction.commit);
    });

    test('a detached HEAD is never offered a push — Git refuses it, and the '
        'button must not promise what the repository cannot do', () {
      final state = snapshot(ahead: 4, detached: true);

      expect(commitActionFor(state), CommitAction.none);
    });

    test('a clean repository with nothing waiting has no button at all', () {
      expect(commitActionFor(snapshot()), CommitAction.none);
    });
  });

  group('stageBatches', () {
    test('stages the files it was given, not `git add -A`: under the '
        "assistant's last turn \"everything\" is the list on screen", () {
      final batches = stageBatches([file('lib/a.dart'), file('lib/b.dart')]);

      expect(batches, [
        ['add', '--', 'lib/a.dart', 'lib/b.dart'],
      ]);
    });

    test('a rename carries both of its paths, or the commit records the '
        'arrival without the departure', () {
      final batches = stageBatches([
        const ReviewFile(
          path: 'lib/new.dart',
          oldPath: 'lib/old.dart',
          kind: ReviewFileKind.renamed,
        ),
      ]);

      expect(batches, [
        ['add', '--', 'lib/old.dart', 'lib/new.dart'],
      ]);
    });

    test('splits a large change set so the command line stays under the limit '
        "Windows enforces at 32 KB", () {
      final files = [for (var i = 0; i < 120; i++) file('lib/f$i.dart')];

      final batches = stageBatches(files, perBatch: 50);

      expect(batches.length, 3);
      expect(batches[0].length, 2 + 50);
      expect(batches[2].length, 2 + 20);
      expect(batches.last.last, 'lib/f119.dart');
    });

    test('nothing to stage runs no command rather than a bare `git add`', () {
      expect(stageBatches(const []), isEmpty);
    });
  });
}
