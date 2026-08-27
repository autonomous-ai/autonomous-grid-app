import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/provider_node/logic/context_ladder.dart';

/// The endpoint form picks a context window from a list rather than a slider,
/// so the list is the only thing standing between a user and a silently changed
/// setting: a rung missing here is a value they can no longer choose, and a
/// rung above the server's ceiling is a start that fails after the join.

void main() {
  group('contextLadder', () {
    test('never offers more than the server can serve', () {
      final ladder = contextLadder(max: 40960, current: 40960);
      expect(ladder.every((rung) => rung <= 40960), isTrue);
      expect(ladder.last, 40960, reason: 'the ceiling is worth offering');
    });

    test('keeps a value already in force even when it is off the ladder', () {
      final ladder = contextLadder(max: 262144, current: 40960);
      expect(
        ladder,
        contains(40960),
        reason:
            'a server launched with --ctx-size 40960 must not be rounded to '
            '32k by the act of opening the picker',
      );
    });

    test('offers the familiar sizes under the ceiling, in order', () {
      final ladder = contextLadder(max: 262144, current: 204800);
      expect(ladder, [4096, 8192, 16384, 32768, 65536, 131072, 204800, 262144]);
    });

    test('a tiny ceiling still yields a usable list, never an empty one', () {
      expect(contextLadder(max: 0, current: 0), [4096]);
      expect(contextLadder(max: 4096, current: 4096), [4096]);
    });

    test('lists every rung once, however the current value lines up', () {
      final ladder = contextLadder(max: 131072, current: 131072);
      expect(ladder.toSet().length, ladder.length);
    });
  });
}
