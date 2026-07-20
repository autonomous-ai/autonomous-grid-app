import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/logic/session_controller.dart';
import 'grid_overview_provider.dart';

/// How often the selected grid's overview is refetched while the user is
/// looking at it.
///
/// Thirty seconds is slow enough that a grid with several nodes isn't polled
/// aggressively, and quick enough that a machine going offline doesn't sit
/// wrong on screen for minutes. Overridable in tests so they don't have to wait
/// on a real clock.
final gridOverviewRefreshIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 30),
);

/// Keeps the selected grid's overview fresh while something is watching it.
///
/// Without this the overview is fetched once per grid switch and then frozen:
/// a node going offline, VRAM changing as an engine loads, a model being added
/// — none of it reaches the screen until the user switches grids or signs in
/// again. That was tolerable when the top bar showed two counts. It isn't once
/// the panel reports hardware totals and per-machine shares, where a stale
/// number reads as a wrong one.
///
/// Deliberately *not* started from a provider `build`: the timer only runs
/// while a widget asks for it, via [GridOverviewRefresh]. A closed panel and a
/// hidden window cost nothing.
class GridOverviewRefresher {
  GridOverviewRefresher(this._ref);

  final Ref _ref;
  Timer? _timer;
  int _watchers = 0;

  /// Whether the timer is currently running — for tests and diagnostics.
  bool get isRunning => _timer != null;

  /// Register a watcher; the first one starts the timer. Every call must be
  /// paired with [release].
  void acquire() {
    _watchers++;
    _start();
  }

  /// Drop a watcher; the last one out stops the timer.
  void release() {
    _watchers = _watchers > 0 ? _watchers - 1 : 0;
    if (_watchers == 0) _stop();
  }

  /// Pause polling — the window went to the background, so a refresh would
  /// spend a request on a screen nobody is looking at.
  void pause() => _stop();

  /// Resume polling, and refresh immediately: coming back to the window is
  /// exactly when the numbers on screen are most likely to be stale.
  void resume() {
    if (_watchers == 0) return;
    _start();
    refreshNow();
  }

  /// Refetch the selected grid's overview right away.
  void refreshNow() {
    final grid = _ref.read(selectedNetworkProvider);
    if (grid == null) return;
    _ref.invalidate(gridOverviewForProvider(grid.networkId));
  }

  void _start() {
    if (_timer != null) return;
    _timer = Timer.periodic(
      _ref.read(gridOverviewRefreshIntervalProvider),
      (_) => refreshNow(),
    );
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => _stop();
}

final gridOverviewRefresherProvider = Provider<GridOverviewRefresher>((ref) {
  final refresher = GridOverviewRefresher(ref);
  ref.onDispose(refresher.dispose);
  return refresher;
});

/// Mount this anywhere the grid overview needs to stay live. It holds the
/// refresher open for as long as it's in the tree, and pauses polling while the
/// window is in the background.
///
/// Renders [child] untouched — it's a lifecycle wrapper, not a layout one.
class GridOverviewRefresh extends ConsumerStatefulWidget {
  const GridOverviewRefresh({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<GridOverviewRefresh> createState() =>
      _GridOverviewRefreshState();
}

class _GridOverviewRefreshState extends ConsumerState<GridOverviewRefresh>
    with WidgetsBindingObserver {
  GridOverviewRefresher? _refresher;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Read in a post-frame callback: acquiring starts a timer, and a provider
    // must not be mutated while the first frame is still building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final refresher = ref.read(gridOverviewRefresherProvider);
      _refresher = refresher;
      refresher.acquire();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refresher?.release();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _refresher?.resume();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _refresher?.pause();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
