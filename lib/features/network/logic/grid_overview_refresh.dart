import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/logic/session_controller.dart';
import 'grid_overview_provider.dart';

/// How often the selected grid's overview is refetched while only the summary
/// pill is on screen.
///
/// The pill carries two slow-moving numbers (online machines, models), so it
/// doesn't earn a fast poll: a minute is quick enough that a machine dropping
/// off doesn't sit wrong for long, and slow enough that a fat overview isn't
/// pulled twice a minute on every tab just to keep a two-count chip current.
/// The faster cadence is reserved for when its live detail is actually on screen
/// ([gridOverviewActiveRefreshIntervalProvider]). Overridable in tests so they
/// don't wait on a real clock.
final gridOverviewRefreshIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 60),
);

/// How often the overview is refetched while the hover panel is open.
///
/// The panel is the one place the fast-moving figures show — VRAM as an engine
/// loads, requests in flight — so it's the one place worth hurrying for. Only
/// runs while the panel is actually open (see [GridOverviewRefresher.setActive]),
/// and the panel opening triggers an immediate refetch, so it never opens onto a
/// minute-old number.
final gridOverviewActiveRefreshIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 15),
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

  /// Whether the fast (panel-open) cadence is in effect — see [setActive].
  bool _active = false;

  /// Whether the timer is currently running — for tests and diagnostics.
  bool get isRunning => _timer != null;

  /// Whether the fast cadence is in effect — for tests and diagnostics.
  bool get isActive => _active;

  /// Register a watcher; the first one starts the timer. Every call must be
  /// paired with [release].
  void acquire() {
    _watchers++;
    _start();
  }

  /// Drop a watcher; the last one out stops the timer and falls back to the
  /// calm cadence, so a fresh mount never inherits a stale "active" from a panel
  /// that closed with the pill.
  void release() {
    _watchers = _watchers > 0 ? _watchers - 1 : 0;
    if (_watchers == 0) {
      _active = false;
      _stop();
    }
  }

  /// Switch cadence: [active] true while the hover panel — the only view of the
  /// fast-moving figures — is open, false when it closes. Opening the panel also
  /// refetches at once, so it never opens onto a minute-old number. A no-op when
  /// nothing is watching (there's no timer to re-time).
  void setActive(bool active) {
    if (_active == active) return;
    _active = active;
    if (_watchers == 0) return;
    _restart();
    if (active) refreshNow();
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

  /// The cadence for the current state — fast while the panel is open, calm
  /// otherwise.
  Duration get _interval => _ref.read(
    _active
        ? gridOverviewActiveRefreshIntervalProvider
        : gridOverviewRefreshIntervalProvider,
  );

  void _start() {
    if (_timer != null) return;
    _timer = Timer.periodic(_interval, (_) => refreshNow());
  }

  /// Re-time a running timer onto the current [_interval] — a plain restart, so
  /// the new cadence takes effect from now rather than the next old tick.
  void _restart() {
    if (_timer == null) return;
    _stop();
    _start();
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
