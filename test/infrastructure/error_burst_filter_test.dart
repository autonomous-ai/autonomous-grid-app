import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/logging/error_burst_filter.dart';

void main() {
  group('ErrorBurstFilter', () {
    late DateTime now;
    late ErrorBurstFilter filter;

    setUp(() {
      now = DateTime(2026, 8, 6, 16, 41);
      filter = ErrorBurstFilter(
        window: const Duration(seconds: 30),
        clock: () => now,
      );
    });

    test('writes the first copy of a failure, which is the one that explains '
        'it', () {
      expect(filter.admit('Bad state'), 'Bad state');
    });

    test('drops the copies a repeating frame error throws after it', () {
      filter.admit('Bad state');
      expect(filter.admit('Bad state'), isNull);
      expect(filter.admit('Bad state'), isNull);
    });

    test('the next copy says how many were swallowed, so the log shows a storm '
        'as a storm and not as one stray line', () {
      filter.admit('Bad state');
      for (var i = 0; i < 3000; i++) {
        filter.admit('Bad state');
      }
      now = now.add(const Duration(seconds: 31));
      expect(filter.admit('Bad state'), contains('+3000'));
    });

    test('a failure that has gone quiet is reported plainly when it comes '
        'back', () {
      filter.admit('Bad state');
      now = now.add(const Duration(seconds: 31));
      expect(filter.admit('Bad state'), 'Bad state');
    });

    test('one repeating failure never silences a different one', () {
      filter.admit('Bad state');
      expect(filter.admit('Cannot hit test'), 'Cannot hit test');
    });

    test('copies that differ only past the first line are the same burst — a '
        'stack trace that shifts by a frame is not a new failure', () {
      filter.admit('Bad state\n#0 first frame');
      expect(filter.admit('Bad state\n#0 a different frame'), isNull);
    });

    test(
      'a flood of distinct failures cannot grow the guard without bound',
      () {
        for (var i = 0; i < 1000; i++) {
          filter.admit('Failure number $i');
        }
        expect(filter.trackedCount, lessThanOrEqualTo(256));
      },
    );
  });
}
