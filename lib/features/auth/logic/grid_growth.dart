import 'dart:math' as math;

/// One turn of the welcome animation, in seconds.
///
/// Six acts hang off this clock, and they are the whole shape of the piece:
///
/// ```
/// 0.00 – 5.32   fifteen named machines land, closer and closer together
/// 5.35 – 8.35   nobody joins — the cluster keeps turning ([spinAt])
/// 8.35 – 9.94   +85 desks: the hundred mark
/// 9.95 – 12.75  +196 workstations and +64 racks: "and it keeps going"
/// 12.75 – 14.15 the tail — machines still landing after the scene has "ended"
/// 14.15 – 15.75 the picture leaves as one layer ([loopFade]), then it repeats
/// ```
const double kWelcomeLoopSeconds = 15.75;

/// The lull: three seconds in which no machine arrives.
///
/// Not a still — the cluster is turning through it. A draft that froze here made
/// everything after it read as a jolt; motion never stops, it only drops its
/// voice, which is what gives the surge something to break.
const double kOrbitFrom = 5.35;
const double kOrbitTo = 8.35;

/// How far the lull carries the cluster, on top of its steady drift (radians).
const double kOrbitTurn = 0.45;

/// The two surges. The first is the hundred mark, the second the one that stops
/// being countable — 196 workstations, then 64 racks half a second behind them.
const double kWave1At = 8.35;
const double kWave2At = 9.95;

/// When the turn starts dissolving, so the loop closes on a breath, not a cut.
const double kFadeAt = 14.15;

/// The single frame Reduce Motion holds (§11): late enough that all three
/// numbers have said what they have to say, early enough that the picture is
/// still whole rather than half-faded.
const double kSettledAt = kWave2At + 2.8;

/// The camera's floor and its shape. It pulls back once and never returns.
const double kViewEnd = 0.22;
const double kViewFrom = 7.90;
const double kViewRate = 1.55;

/// Weights plus working memory for one trillion-parameter model, in GB.
const int kCopyGb = 1400;

/// How far back the camera is at [seconds]: 1 is the opening framing, [kViewEnd]
/// is as far out as it goes.
///
/// **One continuous curve, never keyframes.** A draft interpolated between fixed
/// stops and repeated the same value between two of them, so the picture sat
/// dead still and then jerked. This decays smoothly and is never once flat.
///
/// The exponent 1.5 (anything above 1 would do) puts the derivative at zero when
/// `u` is 0, so the pull-back eases *in* rather than kicking. And it starts
/// before the first surge does ([kViewFrom] < [kWave1At]) — by the time 85
/// machines arrive there is already somewhere to put them.
double viewScale(double seconds) {
  final u = math.max(0.0, seconds - kViewFrom);
  return kViewEnd +
      (1 - kViewEnd) * math.exp(-math.pow(u / kViewRate, 1.5).toDouble());
}

/// The cluster's rotation at [seconds] — an **accumulated angle**, not a speed.
///
/// Writing `angle = clock * rate` and changing `rate` mid-scene snaps every
/// machine at the instant it changes. Integrating up front instead means the
/// smootherstep's derivative is zero at both ends, so the turn accelerates and
/// settles on its own, and the 0.45 rad it gained is carried forward for the
/// rest of the loop rather than being handed back.
double spinAt(double seconds) {
  final p = ((seconds - kOrbitFrom) / (kOrbitTo - kOrbitFrom)).clamp(0.0, 1.0);
  final eased = p * p * p * (p * (p * 6 - 15) + 10);
  return seconds * 0.03 + kOrbitTurn * eased;
}

/// How present the picture is at [seconds] — 1 for the body of the turn, easing
/// to 0 at the seam.
///
/// Applied once, to the whole layer. Letting each shape work out its own exit
/// puts the links, the ring and the pills a few frames apart, which reads as a
/// rendering fault rather than a dissolve.
double loopFade(double seconds) {
  if (seconds <= kFadeAt) return 1;
  final t = ((seconds - kFadeAt) / (kWelcomeLoopSeconds - kFadeAt)).clamp(
    0.0,
    1.0,
  );
  return 1 - t * t;
}

/// Fast out of the gate, slow into place — the arrival curve everything here
/// grows on.
double easeOutCubic(double t) => 1 - math.pow(1 - t, 3).toDouble();

/// One computer with a name on it, at the centre of the story.
///
/// Position is polar and *relative*: [angle] plus a [radius] multiple of
/// whatever ellipse the canvas works out for its own size, so the cluster holds
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

  /// Seconds into the turn when it lands.
  final double joinAt;

  final double angle;

  /// Multiples of whatever ellipse the canvas works out for its own size.
  ///
  /// Zero for machine 0 — the viewer's own computer, alone at the centre before
  /// anything else, which is the "before Grid" the rest of the screen argues
  /// against. Everything that has to leave it out does so by index rather than
  /// by testing this, because it is always the first one.
  final double radius;
}

/// A real office is not fifteen Macs.
///
/// Every memory figure is a configuration you can actually buy, and they add to
/// exactly 700GB — the rung a 671B model fits on — so act one closes on a real
/// number rather than on a warm-up.
///
/// `radius` is the output of a coordinate ascent, not a set of eyeballed values:
/// it maximises the smallest gap between any two pills while pulling every
/// machine onto one of two shells (≈1.05 and ≈1.34), so machines that are
/// neighbours in *time* are not neighbours in *depth*. Fifteen pills on fixed
/// bearings all turn together, so two that overlap overlap forever — and hand
/// tuning one pair breaks another. **Don't nudge a single number here**; if the
/// layout has to change, re-run the optimisation.
const List<(String name, int gb, double radius)> _namedMachines = [
  ('This Mac', 24, 0.00),
  ('Mac Studio', 96, 0.95),
  ('RTX 4090', 24, 1.34),
  ('Mac mini', 32, 1.09),
  ('Ubuntu box', 48, 1.34),
  ('MacBook Pro', 36, 1.06),
  ('RTX 5090', 32, 1.34),
  ('iMac', 16, 1.06),
  ('Threadripper', 128, 1.34),
  ('A6000', 48, 1.15),
  ('MacBook Air', 16, 1.34),
  ('RTX 3090', 24, 1.01),
  ('Gaming PC', 32, 1.34),
  ('Mac Pro', 96, 1.29),
  ('L40S', 48, 1.34),
];

/// The accelerando, written as a rule rather than fifteen typed timestamps: each
/// gap is 78% of the one before it.
///
/// The last four land less than a tenth of a second apart. That is the point —
/// the sense of gathering pace, running straight into the lull with no handover
/// beat of its own.
List<double> _buildJoins() {
  final out = <double>[0.30];
  var at = 1.30, gap = 0.92;
  for (var i = 1; i < _namedMachines.length; i++) {
    out.add(at);
    at += gap;
    gap *= 0.78;
  }
  return out;
}

/// The fifteen, in the order they join.
///
/// Bearings are the golden angle (137.5°) stepped from twelve o'clock: fifteen
/// machines spread evenly around the ellipse with **no two on the same line**,
/// which hand-placed angles cannot promise.
final List<GridMachine> kWelcomeMachines = List.unmodifiable(() {
  final joins = _buildJoins();
  return [
    for (var i = 0; i < _namedMachines.length; i++)
      GridMachine(
        name: _namedMachines[i].$1,
        memoryGb: _namedMachines[i].$2,
        joinAt: joins[i],
        angle: -math.pi / 2 + i * 2.39996,
        radius: _namedMachines[i].$3,
      ),
  ];
}());

/// 700GB — what the named fifteen add up to, and the unit one lap of the hub's
/// capacity ring is worth (§8.6.f).
final int kNamedPoolGb = kWelcomeMachines.fold(0, (sum, m) => sum + m.memoryGb);

/// One machine in a surge: no name, no label, still a machine.
class GridNode {
  const GridNode({
    required this.memoryGb,
    required this.joinAt,
    required this.angle,
    required this.radius,
    required this.spin,
    required this.wobble,
  });

  final int memoryGb;
  final double joinAt;
  final double angle;

  /// Multiples of the same ellipse the named cluster sits on — 1.85 for the
  /// nearest desk, 7.4 for the furthest rack.
  final double radius;

  /// Its own drift, so a surge is a crowd of individuals rather than a texture.
  final double spin;
  final double wobble;
}

/// A wave of machines arriving together — desks, then workstations, then the
/// company's own racks.
///
/// The mix moves outward exactly as a company's hardware does: desks near you,
/// workstations behind them, and the rack room downstairs at the rim. The racks
/// are **not a data centre** — the whole argument is hardware you own rather
/// than rent, and a data centre in the middle of "your grid" would have the
/// picture contradicting the words.
class GridWave {
  const GridWave._({
    required this.at,
    required this.pillWidth,
    required this.pillHeight,
    required this.led,
    required this.nodes,
  });

  /// When the wave opens — also when the whole frame flashes (§8.8).
  final double at;

  /// The pill this wave draws, in the same design units as a named machine's
  /// 80×26. Racks are a square-ish 21×16 rather than a flat bar so that at nine
  /// pixels tall their silhouette still reads as a different kind of hardware.
  final double pillWidth;
  final double pillHeight;

  /// Whether these carry a green power light. Only the desks are ever drawn big
  /// enough for one to land anywhere but on top of the pill's own edge.
  final bool led;

  final List<GridNode> nodes;

  /// Builds a wave's machines once, deterministically.
  ///
  /// The reference implementation runs this LCG in JavaScript, where every
  /// number is a double: `s * 1103515245` blows past the 53-bit mantissa long
  /// before the modulus, so the sequence is the one rounding leaves behind, not
  /// the one exact integers would give. Keeping `s` a `double` here reproduces
  /// it exactly — and that is load-bearing, not pedantry. The spec's milestones
  /// only come out on this stream: 1.4TB at 8.80s (which is what tips the third
  /// column over to "1T"), 21.1TB and 353 machines at 14.06s, 5.91 laps at the
  /// end. Exact integer arithmetic lands 2–3% higher and misses every one.
  factory GridWave.grow({
    required int seed,
    required int count,
    required double at,
    required double span,
    required double r0,
    required double r1,
    required double tail,
    required double ease,
    required List<int> sizes,
    required double pillWidth,
    required double pillHeight,
    required bool led,
  }) {
    var s = seed.toDouble();
    double next() {
      s = (s * 1103515245 + 12345) % 2147483648;
      return s / 2147483648;
    }

    final nodes = <GridNode>[];
    for (var i = 0; i < count; i++) {
      final p = i / count;
      // Draw order is part of the seed: every call below is one step of the same
      // stream, so moving a line moves every machine after it.
      final gb = sizes[(next() * sizes.length).floor()];
      final joinAt =
          at + span * math.pow(p, ease) + tail * math.pow(p, 7).toDouble();
      final angle = next() * 6.2832;
      final radius =
          r0 + (r1 - r0) * (0.68 * math.pow(p, 0.8) + 0.32 * next()).toDouble();
      nodes.add(
        GridNode(
          memoryGb: gb,
          joinAt: joinAt.toDouble(),
          angle: angle,
          radius: radius,
          spin: 0.014 + next() * 0.04,
          wobble: next() * 6.2832,
        ),
      );
    }
    return GridWave._(
      at: at,
      pillWidth: pillWidth,
      pillHeight: pillHeight,
      led: led,
      nodes: List.unmodifiable(nodes),
    );
  }
}

/// The three surges, built once at startup — never per frame.
///
/// Three details here are load-bearing:
///
/// - **`radius` tracks arrival order.** The camera is still close when a wave
///   opens, so early machines have to land *inside*; by the time the late ones
///   arrive it has pulled back far enough to hold them. A purely random radius
///   throws the last wave's first machines outside the frame, where they fly in
///   and vanish at the cull.
/// - **`tail` is `p^7`** — a very thin, very long tail, so the last wave is
///   *still arriving* when the scene "ends". That is the only honest way to draw
///   "∞": not that it is infinite, but that it hasn't stopped.
/// - **`ease` differs per wave.** The desks climb at 1.25 rather than the 1.7 of
///   the other two: with 85 machines, 1.7 is a firehose that swallows the
///   fifteen mark a third of a second after it lands.
final List<GridWave> kGridWaves = List.unmodifiable([
  GridWave.grow(
    seed: 7,
    count: 85,
    at: kWave1At,
    span: 1.60,
    r0: 1.85,
    r1: 3.60,
    tail: 0,
    ease: 1.25,
    sizes: [8, 16, 16, 24, 32, 32],
    pillWidth: 36,
    pillHeight: 13,
    led: true,
  ),
  GridWave.grow(
    seed: 97,
    count: 196,
    at: kWave2At,
    span: 2.40,
    r0: 3.20,
    r1: 5.60,
    tail: 2.3,
    ease: 1.15,
    sizes: [16, 24, 24, 32, 48, 64],
    pillWidth: 19,
    pillHeight: 7,
    led: false,
  ),
  GridWave.grow(
    seed: 53,
    count: 64,
    at: kWave2At + 0.55,
    span: 2.10,
    r0: 5.10,
    r1: 7.40,
    tail: 1.9,
    ease: 1.1,
    sizes: [128, 192, 192, 256],
    pillWidth: 21,
    pillHeight: 16,
    led: false,
  ),
]);

/// The smallest pool that can hold each model size, in GB.
///
/// A threshold table rather than a curve, read top down, first match wins, and
/// always rounded **down** to a size people actually name: 671B is DeepSeek-V3,
/// ~1T is Kimi K2. The screen is claiming something concrete about the user's
/// own machines, so it errs toward under-promising.
const List<(int floorGb, String size, String unit)> _modelLadder = [
  (1400, '1', 'T'),
  (700, '671', 'B'),
  (380, '405', 'B'),
  (300, '235', 'B'),
  (200, '120', 'B'),
  (100, '70', 'B'),
  (40, '32', 'B'),
  (0, '8', 'B'),
];

/// What the grid amounts to at one instant of the turn — the three numbers the
/// rail shows and the sentence under them, derived rather than scripted so they
/// can never drift out of step with the machines actually on screen.
class GridGrowth {
  const GridGrowth({
    required this.seconds,
    required this.machines,
    required this.pooledGb,
    required this.last,
    required this.sinceLastJoin,
  });

  final double seconds;
  final int machines;
  final int pooledGb;

  /// The most recent *named* machine to land. The surges are anonymous by
  /// design, so the receipt line and the hub's ring both settle against this
  /// one — after the surges open, nothing needs a name any more.
  final GridMachine last;

  /// Seconds since [last] landed, so the rail can flash as the numbers change
  /// without holding any state of its own.
  final double sinceLastJoin;

  /// Through the surges the numbers change every frame, so "how long since the
  /// last one" stops meaning anything — hold the flash on instead.
  bool get surging => seconds >= kWave1At && seconds < kSettledAt;

  /// 1 the instant something lands, 0 once the flash has faded.
  double get fresh =>
      surging ? 1.0 : (1 - sinceLastJoin / 0.45).clamp(0.0, 1.0);

  /// The unit flipping from GB to TB is a small, very satisfying bump.
  String get memoryValue =>
      pooledGb >= 1000 ? (pooledGb / 1000).toStringAsFixed(1) : '$pooledGb';
  String get memoryUnit => pooledGb >= 1000 ? 'TB' : 'GB';

  (int, String, String) get _rung =>
      _modelLadder.firstWhere((rung) => pooledGb >= rung.$1);

  int get _copies => pooledGb ~/ kCopyGb;

  /// Past a trillion parameters the ladder runs out, and the honest thing that
  /// keeps growing is not the model's *size* but how many copies of it run at
  /// once — another 1.4TB is another copy, another queue of people answered.
  ///
  /// Printing "2T" would be a claim about a model nobody has published.
  bool get runsInParallel => _copies >= 2;

  String get modelLabel =>
      runsInParallel ? 'Models in parallel' : 'Largest model';
  String get modelValue => runsInParallel ? '$_copies' : _rung.$2;
  String get modelUnit => runsInParallel ? '× 1T' : _rung.$3;

  /// Capacity as laps of the hub's ring — **one lap per doubling of the pool**.
  ///
  /// Linear would need thirty-odd laps by the time the pool is 21TB, which is no
  /// picture at all. A log scale saturates on its own: the turn ends at 5.91
  /// laps against a ceiling of 7 that is never reached.
  ///
  /// Below the named fifteen's own total the ring is still counting *machines*,
  /// easing toward each new one rather than snapping, so a machine landing reads
  /// as a surge. The two meet exactly at 700GB, where both give 1.
  double get capacityLaps {
    if (pooledGb > kNamedPoolGb) {
      return 1 + math.log(pooledGb / kNamedPoolGb) / math.ln2;
    }
    final named = math.min(machines, kWelcomeMachines.length);
    final settle = ((seconds - last.joinAt) / 0.6).clamp(0.0, 1.0);
    return (named - 1 + easeOutCubic(settle)) / kWelcomeMachines.length;
  }

  /// The line under the rail, in two halves: the sentence, and the fact it
  /// lands on.
  ///
  /// Split because only the second half is set in gold — it is the part that
  /// changes, and the eye should find it without reading the sentence again.
  /// Which fact it is changes with the act: a name while machines still have
  /// names, then a count once they stop, then the pool itself.
  (String sentence, String fact) get receipt {
    if (machines == 1) return ('Only this Mac so far.', '');
    if (seconds < kWave1At) {
      return ('${last.name} joined', '+${last.memoryGb}GB');
    }
    if (seconds < kWave2At) {
      return ('The rest of the building is joining', '$machines machines');
    }
    return ('And it keeps going', '$memoryValue$memoryUnit pooled');
  }
}

/// The grid as it stands [seconds] into the turn.
///
/// Clamped to at least one machine: the screen opens on the user's own computer
/// already sitting there, and a rail reading "0 machines" for the first third of
/// a second says something untrue about the box running it.
GridGrowth growthAt(double seconds) {
  var joined = 0;
  var pooled = 0;
  var last = kWelcomeMachines.first;
  for (final machine in kWelcomeMachines) {
    if (seconds < machine.joinAt) continue;
    joined++;
    pooled += machine.memoryGb;
    last = machine;
  }
  if (joined == 0) {
    joined = 1;
    pooled = kWelcomeMachines.first.memoryGb;
  }
  for (final wave in kGridWaves) {
    if (seconds < wave.at) continue;
    for (final node in wave.nodes) {
      if (seconds < node.joinAt) continue;
      joined++;
      pooled += node.memoryGb;
    }
  }
  return GridGrowth(
    seconds: seconds,
    machines: joined,
    pooledGb: pooled,
    last: last,
    sinceLastJoin: seconds - last.joinAt,
  );
}
