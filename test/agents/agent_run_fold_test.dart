import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_run_fold.dart';

void main() {
  group('a saved turn\'s run of steps', () {
    test('a short run is drawn whole — folding four file reads behind a '
        'summary hides work the user can already take in at a glance', () {
      expect(runIsFolded(4), isFalse);
      expect(visibleRunSteps(4, open: false), 4);
    });

    test('a run right on the limit is still whole, so the fold appears only '
        'once there is genuinely more than a screenful', () {
      expect(runIsFolded(kFoldedRun), isFalse);
      expect(visibleRunSteps(kFoldedRun, open: false), kFoldedRun);
    });

    test('the overnight-loop run that froze the window shows its tail, not its '
        '2,662 rows — each step is a stateful row with its own painted guide, '
        'and they are built in one frame', () {
      expect(runIsFolded(2662), isTrue);
      expect(visibleRunSteps(2662, open: false), kFoldedRunTail);
    });

    test('opening one is capped too — asking to see more is not asking for the '
        'window to stop answering', () {
      expect(visibleRunSteps(2662, open: true), kOpenedRunLimit);
    });

    test('opening a run shorter than the ceiling shows all of it, so the cap '
        'never quietly clips a run it could have drawn', () {
      expect(visibleRunSteps(30, open: true), 30);
    });
  });
}
