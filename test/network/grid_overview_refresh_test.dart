import 'package:flutter/material.dart';
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

  group('GridOverviewRefresh widget', () {
    testWidgets('holds the refresher open while mounted', (tester) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: GridOverviewRefresh(child: SizedBox()),
          ),
        ),
      );
      await tester.pump(); // let the post-frame callback run

      expect(refresher.isRunning, isTrue);
    });

    testWidgets('releases it on unmount, leaving no timer behind', (
      tester,
    ) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: GridOverviewRefresh(child: SizedBox()),
          ),
        ),
      );
      await tester.pump();

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: SizedBox()),
        ),
      );

      expect(refresher.isRunning, isFalse);
    });

    testWidgets('renders its child untouched', (tester) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: GridOverviewRefresh(child: Text('pill')),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('pill'), findsOneWidget);
    });
  });
}
