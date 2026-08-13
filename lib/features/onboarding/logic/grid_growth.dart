import 'dart:math' as math;

/// One computer joining the grid during the welcome animation.
///
/// Position is polar and *relative*: [angle] plus a [radius] multiplier of
/// whatever ellipse the band works out for its own size, so the cluster holds
/// its shape in a narrow window as well as a wide one.
class GridMachine {
  const GridMachine({
    required this.name,
    required this.memoryGb,
    required this.joinAt,
    required this.angle,
    required this.radius,
  });

  final String name;

  /// What this machine brings to the pool — the number that makes the point.
  final int memoryGb;

  /// Seconds into the timeline when it lands.
  final double joinAt;

  final double angle;
  final double radius;
}

/// Twelve o'clock, so the first machine sits above the hub rather than beside it.
const double _top = -math.pi / 2;

/// The machines, in the order they join. The first is the user's own — it starts
/// alone at the centre, which is the whole "before" the rest of the screen argues
/// against. The others arrive faster and faster: the point isn't nine specific
/// computers, it's that each one adds to the same pool.
const List<GridMachine> kWelcomeMachines = [
  GridMachine(
    name: 'This Mac',
    memoryGb: 24,
    joinAt: 0.30,
    angle: _top,
    radius: 0,
  ),
  GridMachine(
    name: 'Mac Studio',
    memoryGb: 64,
    joinAt: 1.75,
    angle: _top + 1.05,
    radius: 1.00,
  ),
  GridMachine(
    name: 'RTX 4090',
    memoryGb: 24,
    joinAt: 2.45,
    angle: _top + 2.10,
    radius: 0.95,
  ),
  GridMachine(
    name: 'Mac mini',
    memoryGb: 32,
    joinAt: 3.00,
    angle: _top + 3.14,
    radius: 1.02,
  ),
  GridMachine(
    name: 'Linux box',
    memoryGb: 48,
    joinAt: 3.50,
    angle: _top + 4.19,
    radius: 0.96,
  ),
  GridMachine(
    name: 'MacBook Pro',
    memoryGb: 36,
    joinAt: 3.95,
    angle: _top + 5.24,
    radius: 1.03,
  ),
  GridMachine(
    name: 'Mac Studio',
    memoryGb: 96,
    joinAt: 4.35,
    angle: _top + 0.52,
    radius: 1.46,
  ),
  GridMachine(
    name: 'A6000',
    memoryGb: 48,
    joinAt: 4.70,
    angle: _top + 2.62,
    radius: 1.50,
  ),
  GridMachine(
    name: 'Mac Pro',
    memoryGb: 40,
    joinAt: 5.00,
    angle: _top + 4.71,
    radius: 1.44,
  ),
];

/// When every machine has landed and the grid flashes once, whole.
const double kGridFinaleAt = 5.95;

/// One turn of the loop. The story lands by [kGridFinaleAt], then the finished
/// grid is held — pulses still running inward — long enough to read the three
/// numbers under it before it starts over.
const double kWelcomeLoopSeconds = 13;

/// When the turn begins fading out, so the loop closes on a dissolve rather than
/// a cut from nine machines back to one.
const double _fadeOutAt = 11.6;

/// How present the grid is at [seconds] — 1 for the body of the loop, easing to
/// 0 at the seam. The whole picture is drawn through this, so nothing survives
/// the wrap by a frame.
double loopFade(double seconds) {
  if (seconds <= _fadeOutAt) return 1;
  final t = ((seconds - _fadeOutAt) / (kWelcomeLoopSeconds - _fadeOutAt)).clamp(
    0.0,
    1.0,
  );
  return 1 - t * t;
}

/// The smallest pool that can hold each model size, in GB.
///
/// A threshold table rather than a curve, and rounded *down* to the sizes people
/// actually name — the screen is claiming something concrete about the user's own
/// machines, so it errs toward under-promising.
const List<(int gb, int billions)> _modelLadder = [
  (380, 405),
  (300, 235),
  (200, 120),
  (100, 70),
  (40, 32),
  (0, 8),
];

/// What the grid amounts to at one instant of the timeline — the three numbers
/// the rail shows, derived rather than scripted so they can never drift out of
/// step with the machines actually on screen.
class GridGrowth {
  const GridGrowth({
    required this.machines,
    required this.pooledGb,
    required this.largestModelB,
    required this.sinceLastJoin,
  });

  final int machines;
  final int pooledGb;

  /// Parameter count, in billions, of the largest model this pool can hold.
  final int largestModelB;

  /// Seconds since the most recent machine landed, so the rail can flash the
  /// numbers as they change without holding any state of its own.
  final double sinceLastJoin;
}

/// How many machines have joined by [seconds].
int machinesJoinedAt(double seconds) {
  var count = 0;
  for (final machine in kWelcomeMachines) {
    if (seconds >= machine.joinAt) count++;
  }
  return count;
}

/// The grid as it stands [seconds] into the timeline.
///
/// Clamped to at least one machine: the screen opens on the user's own computer
/// already there, and a rail reading "0 machines" for the first third of a second
/// says something untrue about the box it is running on.
GridGrowth growthAt(double seconds) {
  final joined = math.max(1, machinesJoinedAt(seconds));
  var pooled = 0;
  for (var i = 0; i < joined; i++) {
    pooled += kWelcomeMachines[i].memoryGb;
  }
  var largest = _modelLadder.last.$2;
  for (final (gb, billions) in _modelLadder) {
    if (pooled >= gb) {
      largest = billions;
      break;
    }
  }
  return GridGrowth(
    machines: joined,
    pooledGb: pooled,
    largestModelB: largest,
    sinceLastJoin: seconds - kWelcomeMachines[joined - 1].joinAt,
  );
}
