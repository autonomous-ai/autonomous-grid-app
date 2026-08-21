import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/logic/session_controller.dart';
import 'grid_power_provider.dart';
import 'node_metrics.dart' show formatCount;

/// Whether the grid is working right now, how hard, and — when it isn't — how
/// long it has been quiet.
///
/// This replaced a rolling series (a sparkline of tokens per poll). The series
/// was honest but unreadable: the relay answers once a minute, so the chart
/// gained one point every sixty seconds and took twenty minutes to turn over,
/// and a grid at rest drew a flat line that read as a broken chart rather than
/// as an idle grid. A rate and an idle clock say the same thing in a form that
/// is right at that cadence — and "quiet for 12 minutes" is a measurement a
/// flat line cannot make.
class GridActivity {
  const GridActivity({this.rateTokS, this.lastBusyAt});

  /// Tokens per second across the grid, or null when nothing can say.
  ///
  /// Two sources, in order. The relay's own `throughput_tok_s` is instantaneous
  /// and therefore preferred. Failing that — no node reports it — the step
  /// between two consecutive rollups, divided by the seconds between them,
  /// which is the same quantity measured over a minute instead of a moment.
  final double? rateTokS;

  /// When the grid was last seen working. Null when it has been quiet for the
  /// whole time this app has been watching: the idle clock then shows no figure
  /// rather than counting from the moment the window opened, which would be the
  /// app's uptime wearing the grid's name.
  final DateTime? lastBusyAt;

  bool get isBusy => (rateTokS ?? 0) > 0;

  /// How long since work was last seen, or null when that was never seen.
  Duration? idleFor(DateTime now) {
    final since = lastBusyAt;
    if (since == null || isBusy) return null;
    return now.difference(since);
  }
}

/// Tracks [GridActivity] for the selected grid.
///
/// Resets on grid switch: one grid's idle clock is not another's.
class GridActivityNotifier extends Notifier<GridActivity> {
  /// The rollup reading the fallback rate is measured against.
  int? _lastFresh;
  DateTime? _lastAt;

  /// Keeps the idle clock moving while nothing else does.
  ///
  /// [gridPowerProvider] has value equality, so a quiet grid polled twice
  /// produces no notification at all — which is right for the figures and wrong
  /// for a clock. Without this the bar would freeze at "idle 3m" for the rest of
  /// the afternoon. Runs only while idle, and only once a minute, which is the
  /// resolution the label is written at anyway.
  Timer? _idleTick;

  @override
  GridActivity build() {
    ref.watch(selectedNetworkProvider);
    _lastFresh = null;
    _lastAt = null;
    ref.onDispose(() => _idleTick?.cancel());
    // Not `fireImmediately`: a notifier may not write its own state inside
    // build. The current reading is taken by hand, as the initial value.
    ref.listen<GridPower>(gridPowerProvider, (_, next) => _sample(next));
    final power = ref.read(gridPowerProvider);
    _seed(power);
    final rate = power.throughputTokS;
    return GridActivity(
      rateTokS: rate,
      lastBusyAt: (rate ?? 0) > 0 ? DateTime.now() : null,
    );
  }

  void _seed(GridPower power) {
    final answered = power.answered;
    if (answered == null) return;
    _lastFresh = answered.freshInputTokens;
    _lastAt = DateTime.now();
  }

  void _sample(GridPower power) {
    final now = DateTime.now();
    final rate = power.throughputTokS ?? _stepRate(power, now);
    final busy = (rate ?? 0) > 0;
    state = GridActivity(
      rateTokS: rate,
      lastBusyAt: busy ? now : state.lastBusyAt,
    );
    _armIdleTick(busy);
  }

  /// The fallback rate: tokens that arrived between two rollups, per second.
  ///
  /// Refused rather than smoothed in three cases, each of which would draw work
  /// the grid did not do: no rollup at all (an older relay — absent is not
  /// zero); a step backwards (the window is rolling, so tokens age out of it,
  /// and a quiet grid can report less than it did a minute ago); and two
  /// readings inside the same second, which would divide by almost nothing.
  double? _stepRate(GridPower power, DateTime now) {
    final answered = power.answered;
    if (answered == null) return null;

    final fresh = answered.freshInputTokens;
    final lastFresh = _lastFresh;
    final lastAt = _lastAt;
    _lastFresh = fresh;
    _lastAt = now;
    if (lastFresh == null || lastAt == null) return null;

    final elapsed = now.difference(lastAt).inMilliseconds / 1000;
    if (elapsed < 1) return null;

    final delta = fresh - lastFresh;
    return delta <= 0 ? 0 : delta / elapsed;
  }

  void _armIdleTick(bool busy) {
    if (busy) {
      _idleTick?.cancel();
      _idleTick = null;
      return;
    }
    _idleTick ??= Timer.periodic(const Duration(minutes: 1), (_) {
      // A new instance with the same fields: [GridActivity] carries no value
      // equality, so this is what moves the clock on the label.
      state = GridActivity(
        rateTokS: state.rateTokS,
        lastBusyAt: state.lastBusyAt,
      );
    });
  }
}

final gridActivityProvider =
    NotifierProvider.autoDispose<GridActivityNotifier, GridActivity>(
      GridActivityNotifier.new,
    );

/// The rate as the capsule writes it — "~967", "~1.2K".
///
/// Rounded, and marked as approximate: the underlying figure is each node's own
/// estimate summed across machines that measured it at slightly different
/// moments, and decimals would claim a precision nobody has.
String formatRate(double tokS) {
  final rounded = tokS.round();
  return rounded >= 1000 ? '~${formatCount(rounded)}' : '~$rounded';
}

/// "idle 12m" — how long the grid has been quiet, at the resolution that is
/// worth saying.
///
/// Under a minute is just "idle": a grid between two turns is not news, and a
/// clock ticking in seconds on the top bar would be movement in the corner of
/// the eye for no reason. Hours from sixty minutes up, because "idle 97m" is a
/// number the reader has to divide.
String idleLabel(Duration since) {
  final minutes = since.inMinutes;
  if (minutes < 1) return 'idle';
  if (minutes < 60) return 'idle ${minutes}m';
  return 'idle ${since.inHours}h';
}
