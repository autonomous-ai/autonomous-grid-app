import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/grid_overview_refresh.dart';

/// The refresher owns a repeating timer, so the risk isn't that it fails to
/// fire — it's that it keeps firing after the pill is gone, or runs while the
/// window is in the background. These pin the lifecycle.
void main() {
  late ProviderContainer container;
  late GridOverviewRefresher refresher;

  setUp(() {
    container = ProviderContainer(
      overrides: [
        gridOverviewRefreshIntervalProvider.overrideWithValue(
          const Duration(milliseconds: 20),
        ),
        gridOverviewActiveRefreshIntervalProvider.overrideWithValue(
          const Duration(milliseconds: 4),
        ),
      ],
    );
    refresher = container.read(gridOverviewRefresherProvider);
  });

  tearDown(() => container.dispose());

  group('GridOverviewRefresher lifecycle', () {
    test('is idle until something asks for it', () {
      expect(refresher.isRunning, isFalse);
    });

    test('runs while a watcher holds it', () {
      refresher.acquire();
      expect(refresher.isRunning, isTrue);
    });

    test('stops when the last watcher leaves', () {
      refresher.acquire();
      refresher.release();
      expect(refresher.isRunning, isFalse);
    });

    test('keeps running while a second watcher is still holding', () {
      refresher.acquire();
      refresher.acquire();
      refresher.release();

      expect(
        refresher.isRunning,
        isTrue,
        reason: 'one watcher left, but another is still watching',
      );

      refresher.release();
      expect(refresher.isRunning, isFalse);
    });

    test('an unbalanced release never drives the count negative', () {
      // A stray release must not leave the counter at -1, where the next
      // acquire/release pair would fail to stop the timer.
      refresher.release();
      refresher.acquire();
      refresher.release();

      expect(refresher.isRunning, isFalse);
    });

    test('pausing stops the timer, resuming starts it again', () {
      refresher.acquire();
      refresher.pause();
      expect(refresher.isRunning, isFalse);

      refresher.resume();
      expect(refresher.isRunning, isTrue);
    });

    test('resume does nothing when nobody is watching', () {
      // The window came forward while the pill was unmounted: there is no one
      // to refresh for, and starting a timer here would leak one.
      refresher.resume();
      expect(refresher.isRunning, isFalse);
    });

    test('acquiring twice does not stack timers', () {
      refresher.acquire();
      refresher.acquire();
      refresher.release();
      refresher.release();

      expect(
        refresher.isRunning,
        isFalse,
        reason: 'a second timer would survive both releases',
      );
    });
  });

  group('adaptive cadence', () {
    test('starts on the calm cadence, not the fast one', () {
      refresher.acquire();
      expect(refresher.isActive, isFalse);
    });

    test('opening the panel switches to the fast cadence', () {
      refresher.acquire();
      refresher.setActive(true);
      expect(refresher.isActive, isTrue);
      expect(refresher.isRunning, isTrue);
    });

    test('closing it falls back to the calm cadence', () {
      refresher.acquire();
      refresher.setActive(true);
      refresher.setActive(false);
      expect(refresher.isActive, isFalse);
    });

    test('setActive is a no-op when nobody is watching', () {
      // The pill mounts the refresher even for an empty grid (no panel drawn),
      // so a setActive that arrived without a watcher must not start a timer.
      refresher.setActive(true);
      expect(refresher.isRunning, isFalse);
      expect(refresher.isActive, isTrue);
    });

    test(
      'a watcher leaving resets the fast cadence, so the next mount is calm',
      () {
        refresher.acquire();
        refresher.setActive(true);
        refresher.release();

        refresher.acquire();
        expect(
          refresher.isActive,
          isFalse,
          reason: 'a panel that closed with the pill must not leave it hurried',
        );
      },
    );

    test('going active while watched keeps a single running timer', () {
      // Switching cadence re-times the timer rather than stacking a second one:
      // a leaked timer here would poll the overview twice as often as intended.
      refresher.acquire();
      refresher.setActive(true);
      refresher.release();
      expect(refresher.isRunning, isFalse);
    });
  });
}
