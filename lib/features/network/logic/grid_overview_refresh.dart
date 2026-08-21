import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/logic/session_controller.dart';
import 'grid_overview_provider.dart';

/// How often the selected grid's overview is refetched while only the summary
/// pill is on screen.
///
/// A minute, while the pill carried two slow-moving counts: nothing on it moved
/// fast enough to earn a fat payload twice a minute. It carries two live ones
/// now — the rate the grid is working at, which drives the bars beside it, and
/// the share of memory in use, which drives the ring. Both are readings of
/// *this moment*, so a minute-old one is a minute-old claim about a grid the
/// user is deciding whether to send work to.
///
/// Twenty seconds is the shortest interval that still leaves the fetch idle most
/// of the time. The faster cadence is still reserved for when the panel's live
/// detail is actually open ([gridOverviewActiveRefreshIntervalProvider]).
/// Overridable in tests so they don't wait on a real clock.
final gridOverviewRefreshIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 20),
);

/// How often the selected grid's overview is refetched for the first
/// [kOverviewWarmupSamples] rounds after the pill mounts or the grid changes.
///
/// Only one thing still needs more than a single reading: when the relay reports
/// no `throughput_tok_s`, `GridActivity` falls back to the step between two
/// consecutive rollups, and a step needs a second poll before it exists. At the
/// calm cadence that is twenty seconds of a grid that is plainly working
/// showing `idle`. Five seconds gets the second reading before anyone has
/// finished reading the screen they just opened.
///
/// The burst is the cost of *starting* a measurement, not of keeping one — so
/// it is two rounds, not a filling animation.
final gridOverviewWarmupRefreshIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 5),
);

/// How many quick rounds the warm-up runs for.
///
/// Two: one to set the baseline, one to make a step out of it. It was eight
/// while the bar drew a trend line and every extra point was a visible
/// improvement to the shape; a rate needs exactly two, and the other six were a
/// fat payload each, bought for nothing.
const kOverviewWarmupSamples = 2;

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

  /// Rounds served since the current series started. Below
  /// [kOverviewWarmupSamples] the burst cadence is in effect.
  int _warmupTicks = 0;

  /// The grid the warm-up counter belongs to. A different one means a different
  /// series — the history resets on grid switch, so the burst that fills it has
  /// to run again.
  String? _warmupGridId;

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

  /// The cadence for the current state — fast while the panel is open, faster
  /// still until the first rate can be measured, calm otherwise.
  Duration get _interval {
    if (_active) return _ref.read(gridOverviewActiveRefreshIntervalProvider);
    if (_warmupTicks < kOverviewWarmupSamples) {
      return _ref.read(gridOverviewWarmupRefreshIntervalProvider);
    }
    return _ref.read(gridOverviewRefreshIntervalProvider);
  }

  /// Start the warm-up over when the selection moved. Checked here rather than
  /// watched: the refresher is not a widget and holds no subscription of its
  /// own, and every scheduling decision passes through this point anyway.
  void _noteGrid() {
    final id = _ref.read(selectedNetworkProvider)?.networkId;
    if (id == _warmupGridId) return;
    _warmupGridId = id;
    _warmupTicks = 0;
  }

  /// A chain of one-shot timers rather than [Timer.periodic]: the cadence
  /// changes *while it runs* — the warm-up hands over to the calm interval after
  /// two rounds — and a periodic timer is fixed at the period it was created
  /// with.
  void _start() {
    if (_timer != null) return;
    _schedule();
  }

  void _schedule() {
    _noteGrid();
    _timer = Timer(_interval, () {
      _timer = null;
      if (_warmupTicks < kOverviewWarmupSamples) _warmupTicks++;
      refreshNow();
      if (_watchers > 0) _schedule();
    });
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
