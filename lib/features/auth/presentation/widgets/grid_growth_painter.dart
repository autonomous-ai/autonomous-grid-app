import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../logic/grid_growth.dart';
import 'grid_canvas.dart';
import 'grid_hub_instrument.dart';

/// Ambient dust, seeded once so the field is identical on every run and on every
/// machine — which a `Random()` per frame would not be.
final List<_Mote> _dust = () {
  final rng = math.Random(11);
  return List<_Mote>.generate(
    34,
    (_) => _Mote(
      x: rng.nextDouble(),
      y: rng.nextDouble(),
      size: 0.4 + rng.nextDouble() * 0.9,
      phase: rng.nextDouble() * 6.2832,
      speed: 0.2 + rng.nextDouble() * 0.3,
    ),
  );
}();

class _Mote {
  const _Mote({
    required this.x,
    required this.y,
    required this.size,
    required this.phase,
    required this.speed,
  });
  final double x;
  final double y;
  final double size;
  final double phase;
  final double speed;
}

/// One frame of the welcome grid: fifteen computers with names on them, then
/// three hundred and forty-five without, all wired into one hub.
///
/// Driven straight off the animation rather than rebuilt per frame — the caches
/// here (laid-out text, the per-wave position slots) only pay for themselves if
/// the painter outlives a single frame, and a `CustomPaint` whose painter is
/// reconstructed sixty times a second throws them away sixty times a second.
///
/// Takes its colours rather than reading tokens, because a painter runs outside
/// the widget that watched the theme — passing them in is what makes the picture
/// follow a Light/Dark flip (see the `AppTheme.watch` trap).
///
/// The layers below are in draw order, and it is not arbitrary: dust sits under
/// everything and outside the loop's dissolve, and the hub goes down before the
/// named pills so its capacity ring reads as being *behind* the machines rather
/// than punched through them.
class GridGrowthPainter extends CustomPainter {
  GridGrowthPainter({required this.clock, required this.colors})
    : _hub = GridHubInstrument(colors),
      super(repaint: clock);

  /// 0 → 1 across one [kWelcomeLoopSeconds] turn.
  final Animation<double> clock;
  final GridPalette colors;

  final GridHubInstrument _hub;

  final Paint _fill = Paint();
  final Paint _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1;

  /// Allocating a `Paint`, a position list or a `TextPainter` inside the node
  /// loop is the first cause of jank here — at the peak that would be ~700
  /// objects a frame. Everything per-node is written into these instead.
  late final List<Offset> _named = List<Offset>.filled(
    kWelcomeMachines.length,
    Offset.zero,
  );

  /// Per wave, six floats a machine: x, y, arrive, calm, age, gb.
  late final List<Float32List> _slots = [
    for (final wave in kGridWaves) Float32List(wave.nodes.length * 6),
  ];
  final List<int> _live = List<int>.filled(kGridWaves.length, 0);

  late final CanvasText _label = CanvasText(weight: FontWeight.w500);

  /// Two receipt caches for one string shape, and the reason is the cache
  /// itself: a bucket is thrown away when its size moves 2%, and these two are
  /// drawn at different scales (`nodeScale` and `mScale`) in the same frame.
  /// Sharing one, each pass would evict the other's layouts sixty times a
  /// second — a cache that only costs.
  late final CanvasText _waveReceipt = CanvasText(weight: FontWeight.w700);
  late final CanvasText _namedReceipt = CanvasText(weight: FontWeight.w700);

  @override
  void paint(Canvas canvas, Size size) {
    final sec = clock.value * kWelcomeLoopSeconds;
    // Floors, so a pane dragged down to nothing doesn't divide the whole scene
    // by near-zero on the way there.
    final w = math.max(300.0, size.width);
    final h = math.max(260.0, size.height);
    final base = (w / 640).clamp(0.8, 1.35);

    // The camera. **Positions ride this; sizes must not.** Multiplying a pill by
    // the same 0.22 that collapses its position put the last wave under 1.2px a
    // machine — 279 of 298 nodes became invisible dust, and the crowd is the
    // entire point of the last act. Hence four separate curves.
    final view = viewScale(sec);
    final nodeScale = base * (0.36 + 0.64 * view);
    final mScale = base * (0.20 + 0.80 * view);
    // Has to stay above the named curve at every zoom, or once the crowd is
    // drawn as pills too the hub stops being the biggest thing on screen and the
    // centre reads as one more machine.
    final hubScale = base * math.max(0.34 + 0.66 * view, 0.58);
    // The named cluster keeps a core radius so it never collapses into the ring.
    final coreView = math.max(view, 0.34);
    final charge = ((1 - view) / (1 - kViewEnd)).clamp(0.0, 1.0);

    final centre = Offset(w / 2, h / 2);
    final rxB = math.min(w * 0.28, 470.0);
    final ryB = math.min(h * 0.30, 200.0);
    final ringR = GridHubInstrument.ringRadius(hubScale);

    _paintDust(canvas, sec, w, h);

    final growth = growthAt(sec);
    final flash = _flashAt(sec);

    // The whole picture leaves as one layer. Letting each shape work out its own
    // exit puts the wires, the ring and the pills a few frames apart, which
    // reads as a rendering fault rather than a dissolve — so the fade is applied
    // here, once, and appears in none of the alphas below.
    final fade = loopFade(sec);
    if (fade < 1) {
      canvas.saveLayer(
        Offset.zero & size,
        Paint()..color = Colors.black.withValues(alpha: fade),
      );
    }

    _placeNamed(sec, centre, rxB * coreView, ryB * coreView, view);
    _paintNamedLinks(canvas, sec, flash);
    _paintPulses(canvas, sec, charge, flash, view);
    _paintWaves(canvas, sec, centre, rxB, ryB, view, nodeScale, ringR, w, h);

    _hub.paint(
      canvas,
      centre: _named.first,
      seconds: sec,
      scale: hubScale,
      charge: charge,
      flash: flash,
      grown: easeOutCubic(
        ((sec - kWelcomeMachines.first.joinAt) / 0.55).clamp(0.0, 1.0),
      ),
      filled: growth.capacityLaps,
    );

    _paintNamed(canvas, sec, mScale, view, flash);

    if (flash > 0) {
      _fill.color = colors.boltHot.withValues(alpha: flash * 0.13);
      canvas.drawRect(Offset.zero & size, _fill);
    }
    if (fade < 1) canvas.restore();
  }

  /// One short flare each time a wave opens — an accent laid over motion that
  /// never stops, rather than a pause the motion has to make room for.
  ///
  /// Worked out at the top of the frame although it is drawn at the bottom: five
  /// layers read it, three of them inside the hub, and a value derived where it
  /// is *drawn* would hand them the previous frame's number at exactly the
  /// moment it matters.
  double _flashAt(double sec) {
    var flash = 0.0;
    for (final wave in kGridWaves) {
      final age = sec - wave.at;
      if (age < 0 || age >= 0.9) continue;
      flash = math.max(flash, math.pow(1 - age / 0.9, 2).toDouble());
    }
    return flash;
  }

  /// Under everything, and outside the dissolve: atmosphere, not decoration.
  void _paintDust(Canvas canvas, double sec, double w, double h) {
    for (final mote in _dust) {
      final y = (mote.y + sec * mote.speed * 0.02) % 1;
      _fill.color = colors.faint.withValues(
        alpha: (0.14 * (0.55 + 0.45 * math.sin(sec * 0.7 + mote.phase))).clamp(
          0.0,
          1.0,
        ),
      );
      canvas.drawCircle(Offset(mote.x * w, y * h), mote.size, _fill);
    }
  }

  /// Where the fifteen sit this frame.
  ///
  /// Their own bearing plus [spinAt] — a rotation applied to this cluster and
  /// nothing else, so the named machines keep turning through the lull while the
  /// crowd behind them drifts on its own — and a small independent wobble that
  /// shrinks with the camera, so the grid looks alive rather than printed.
  void _placeNamed(
    double sec,
    Offset centre,
    double rx,
    double ry,
    double view,
  ) {
    final spin = spinAt(sec);
    for (var i = 0; i < kWelcomeMachines.length; i++) {
      final machine = kWelcomeMachines[i];
      final angle = machine.angle + spin;
      _named[i] = Offset(
        centre.dx +
            math.cos(angle) * rx * machine.radius +
            math.sin(sec * 0.6 + i * 1.7) * 2.4 * view,
        centre.dy +
            math.sin(angle) * ry * machine.radius +
            math.cos(sec * 0.5 + i) * 1.8 * view,
      );
    }
  }

  /// Every machine to the hub, then each to the one before it.
  ///
  /// Spokes first and the chain second is deliberate: the early machines have to
  /// read as *joining you* before they read as *a network*. The chain starts at
  /// machine 2 because machine 1's would run to the hub — the same segment its
  /// spoke already draws, on a second growth curve and at a doubled hairline.
  void _paintNamedLinks(Canvas canvas, double sec, double flash) {
    for (var i = 1; i < kWelcomeMachines.length; i++) {
      _link(canvas, sec, 0, i, kWelcomeMachines[i].joinAt + 0.10, flash);
    }
    for (var i = 2; i < kWelcomeMachines.length; i++) {
      _link(canvas, sec, i - 1, i, kWelcomeMachines[i].joinAt + 0.30, flash);
    }
  }

  void _link(
    Canvas canvas,
    double sec,
    int from,
    int to,
    double at,
    double flash,
  ) {
    final progress = ((sec - at) / 0.55).clamp(0.0, 1.0);
    if (progress <= 0) return;
    _stroke
      ..color = colors.hair
      ..strokeWidth = 1;
    canvas.drawLine(
      _named[from],
      Offset.lerp(_named[from], _named[to], easeOutCubic(progress))!,
      _stroke,
    );
    // A wire only gets its gold twin once it is whole. Overdrawn while it is
    // still growing, the twin runs the full length and the wire looks doubled.
    if (flash > 0 && progress >= 1) {
      _stroke
        ..color = colors.boltHot.withValues(alpha: flash * 0.5)
        ..strokeWidth = 1.3;
      canvas.drawLine(_named[from], _named[to], _stroke);
    }
  }

  /// Capacity travelling **inward**, one mote per wired spoke.
  ///
  /// The direction is the message: what flows here is the machines' power
  /// arriving at the grid, not the reader's work leaving it. Reversed, the
  /// picture says the opposite of the product.
  void _paintPulses(
    Canvas canvas,
    double sec,
    double charge,
    double flash,
    double view,
  ) {
    final rate = 0.55 + charge * 3.4;
    final radius = (2 + flash) * math.max(view, 0.55);
    for (var i = 1; i < kWelcomeMachines.length; i++) {
      if (sec < kWelcomeMachines[i].joinAt + 0.7) continue;
      final t = (sec * rate + i * 0.13) % 1;
      final eased = t * t * (3 - 2 * t);
      _fill.color = (flash > 0.25 ? colors.boltHot : colors.bolt).withValues(
        alpha: (0.9 * math.sin(t * math.pi)).clamp(0.0, 1.0),
      );
      canvas.drawCircle(
        Offset.lerp(_named[i], _named.first, eased)!,
        radius,
        _fill,
      );
    }
  }

  /// The three surges: **positions first, then every wire, then every machine.**
  ///
  /// Drawn a node at a time instead — wire, pill, wire, pill — a later arrival's
  /// wire crosses an earlier arrival's pill and the whole field reads as cabling
  /// lying on top of the hardware.
  void _paintWaves(
    Canvas canvas,
    double sec,
    Offset centre,
    double rxB,
    double ryB,
    double view,
    double nodeScale,
    double ringR,
    double w,
    double h,
  ) {
    for (var wi = 0; wi < kGridWaves.length; wi++) {
      final wave = kGridWaves[wi];
      final slot = _slots[wi];
      var live = 0;
      if (sec >= wave.at) {
        for (final node in wave.nodes) {
          final age = sec - node.joinAt;
          if (age <= 0) continue;
          final arrive = easeOutCubic((age / 0.5).clamp(0.0, 1.0));
          final angle = node.angle + sec * node.spin;
          final dx = math.cos(angle);
          final dy = math.sin(angle);
          final tx =
              centre.dx +
              dx * rxB * view * node.radius +
              math.sin(sec * 0.7 + node.wobble) * 3 * view;
          final ty =
              centre.dy +
              dy * ryB * view * node.radius +
              math.cos(sec * 0.6 + node.wobble) * 2 * view;
          // Flies in from off-frame, on the same bearing it will land on.
          final x = _lerp(centre.dx + dx * w * 1.05, tx, arrive);
          final y = _lerp(centre.dy + dy * h * 1.25, ty, arrive);
          if (x < -40 || x > w + 40 || y < -40 || y > h + 40) continue;
          // Atmospheric perspective. Without it the far field arrives with the
          // same weight as the machines beside you and the frame turns to
          // noise — depth is what makes a crowd read as a crowd rather than as
          // a texture.
          final depth = (1 - (node.radius - 1.8) / 9).clamp(0.30, 1.0);
          final base = live * 6;
          slot[base] = x;
          slot[base + 1] = y;
          slot[base + 2] = arrive;
          slot[base + 3] = depth * (0.48 + 0.52 * view);
          slot[base + 4] = age;
          slot[base + 5] = node.memoryGb.toDouble();
          live++;
        }
      }
      _live[wi] = live;
    }

    _paintWaveWires(canvas, centre, ringR);
    _paintWavePills(canvas, nodeScale);
  }

  /// A machine with no wire is not on the grid, however small it is drawn.
  ///
  /// They stop short of the capacity ring: three hundred lines converging on one
  /// point paint a solid disc over the very thing they are connecting to. The
  /// 1.28 is measured rather than chosen — see [GridHubInstrument.ringRadius],
  /// which is where the radius it multiplies comes from.
  void _paintWaveWires(Canvas canvas, Offset centre, double ringR) {
    final stopAt = ringR * 1.28;
    _stroke.strokeWidth = 1;
    for (var wi = 0; wi < kGridWaves.length; wi++) {
      final slot = _slots[wi];
      for (var i = 0; i < _live[wi]; i++) {
        final base = i * 6;
        final x = slot[base];
        final y = slot[base + 1];
        final dx = centre.dx - x;
        final dy = centre.dy - y;
        final d = math.sqrt(dx * dx + dy * dy);
        if (d <= stopAt) continue;
        final k = (d - stopAt) / d;
        // `hair` carries its own alpha, so this rides on top of it rather than
        // replacing it — and 0.7 is the same factor the pill rims use, which is
        // what keeps a wire exactly as present as the machine on its end.
        _stroke.color = colors.hair.withValues(
          alpha: colors.hair.a * slot[base + 2] * slot[base + 3] * 0.7,
        );
        canvas.drawLine(Offset(x, y), Offset(x + dx * k, y + dy * k), _stroke);
      }
    }
  }

  /// A machine, not a particle.
  ///
  /// Drawn with `arc()` the crowd reads as *weather* — dust, a particle field —
  /// and the rail can say a hundred while the eye still counts fifteen
  /// computers. It has to be the same pill as the named ones, smaller, with no
  /// room for a name.
  void _paintWavePills(Canvas canvas, double nodeScale) {
    final receiptSize = 10 * nodeScale;
    for (var wi = 0; wi < kGridWaves.length; wi++) {
      final wave = kGridWaves[wi];
      final slot = _slots[wi];
      final ph = math.max(3.5, wave.pillHeight * nodeScale);
      final corner = Radius.circular(math.min(ph / 2.6, 3.5));
      for (var i = 0; i < _live[wi]; i++) {
        final base = i * 6;
        final x = slot[base];
        final arrive = slot[base + 2];
        final calm = slot[base + 3];
        final age = slot[base + 4];
        final gb = slot[base + 5].round();

        final pw = math.max(8.0, (wave.pillWidth + gb / 26) * nodeScale);
        final left = x - pw / 2;
        final top = slot[base + 1] - ph / 2;
        final pill = RRect.fromRectAndRadius(
          Rect.fromLTWH(left, top, pw, ph),
          corner,
        );
        final hot = age < 0.45;

        _fill.color = colors.cardBg.withValues(alpha: arrive * calm * 0.82);
        canvas.drawRRect(pill, _fill);

        // Gold marks **arrival only**. Once a machine has settled its rim cools
        // to the neutral hairline: 345 gold rims would spread the accent over
        // the whole frame and leave nothing accented.
        final rim = hot ? colors.boltHot : colors.hair;
        _stroke
          ..color = rim.withValues(
            alpha: rim.a * arrive * (hot ? 0.95 : calm * 0.62),
          )
          ..strokeWidth = 1;
        canvas.drawRRect(pill, _stroke);

        // Rack units: two hairlines across the block, so it reads as stacked
        // iron rather than one big laptop. Dropped once the block is too short
        // to hold them without turning into a smudge.
        if (wave.pillHeight > 14 && ph > 9) {
          _stroke.color = colors.hair.withValues(
            alpha: colors.hair.a * arrive * calm * 0.5,
          );
          for (var k = 1; k <= 2; k++) {
            final ly = (top + ph * k / 3).roundToDouble() + 0.5;
            canvas.drawLine(
              Offset(left + 2, ly),
              Offset(left + pw - 2, ly),
              _stroke,
            );
          }
        }

        if (wave.led && ph > 8) {
          _fill.color = colors.online.withValues(alpha: arrive * calm * 0.8);
          canvas.drawCircle(
            Offset(left + pw - ph * 0.34, top + ph * 0.32),
            ph * 0.11,
            _fill,
          );
        }

        // The receipt for what this machine just added, exactly as the named
        // ones get one. **Both gates are load-bearing**: ungated, the last wave
        // fires ~190 of these at once and the middle of the frame becomes a wall
        // of gold text. Gated, the peak is ~47 falling to 12 — and the gate
        // itself draws the density gradient a real eye would see, where the near
        // machines are labelled and the far ones are only shapes.
        if (age < 1.0 && receiptSize >= 6.5 && calm > 0.30) {
          _waveReceipt.paintCentred(
            canvas,
            '+${gb}GB',
            Offset(x, top - (7 + math.min(7.0, age * 15)) * nodeScale),
            size: receiptSize,
            color: colors.bolt.withValues(
              alpha: ((1 - age) * 0.95 * calm).clamp(0.0, 1.0),
            ),
          );
        }
      }
    }
  }

  /// The fifteen with names on them.
  ///
  /// The hub is machine 0 and does **not** come through here — it is drawn as an
  /// instrument in [GridHubInstrument]. A few `isHub ? … : …` branches inside
  /// this loop is exactly what kept it looking like a slightly bigger pill.
  void _paintNamed(
    Canvas canvas,
    double sec,
    double mScale,
    double view,
    double flash,
  ) {
    // Names go out during the first surge, once they are too small to read —
    // 7px type at 45% only dirties the picture. The hub's wordmark is the one
    // label that never fades, and it lives in the instrument.
    final nameAlpha = ((view - 0.52) / 0.25).clamp(0.0, 1.0);
    for (var i = 1; i < kWelcomeMachines.length; i++) {
      final machine = kWelcomeMachines[i];
      final age = sec - machine.joinAt;
      if (age <= 0) continue;
      final at = _named[i];
      final grown = easeOutCubic((age / 0.55).clamp(0.0, 1.0));

      // A machine joining the grid has to be an **event**, not one more box that
      // turned up.
      if (age < 0.85) {
        final shock = age / 0.85;
        _stroke
          ..color = colors.bolt.withValues(alpha: (1 - shock) * 0.45)
          ..strokeWidth = 1.3;
        canvas.drawCircle(at, (10 + shock * 44) * mScale, _stroke);
      }

      final width = 80 * mScale * (0.88 + 0.12 * grown);
      final height = 26 * mScale * (0.88 + 0.12 * grown);
      final body = Rect.fromLTWH(
        at.dx - width / 2,
        at.dy - height / 2 + (1 - grown) * 8 * mScale,
        width,
        height,
      );
      final pill = RRect.fromRectAndRadius(body, Radius.circular(9 * mScale));

      _fill.color = colors.cardBg.withValues(alpha: grown);
      canvas.drawRRect(pill, _fill);
      // The rim is what makes a machine a thing, in **both** themes. The fill
      // used to carry it in dark, back when the page was near-black; on the
      // charcoal page it is now 1.065:1 against it — worse than light's 1.110.
      // So neither theme can lean on the fill any more.
      final rim = flash > 0.35 ? colors.boltHot : colors.hair;
      _stroke
        ..color = rim.withValues(alpha: rim.a * grown)
        ..strokeWidth = 1;
      canvas.drawRRect(pill, _stroke);

      if (nameAlpha > 0.02) {
        _label.paintCentred(
          canvas,
          machine.name,
          at,
          size: 10.5 * mScale,
          color: colors.label.withValues(alpha: grown * nameAlpha),
        );
      }

      _fill.color = colors.online.withValues(alpha: grown);
      canvas.drawCircle(
        Offset(body.right - 8 * mScale, body.top + 7 * mScale),
        2 * mScale,
        _fill,
      );

      // What this machine just added, said once and then gone. The rail below
      // keeps the running total; this is only the receipt.
      if (age < 1.5 && nameAlpha > 0.4) {
        _namedReceipt.paintCentred(
          canvas,
          '+${machine.memoryGb}GB',
          Offset(at.dx, body.top - (10 + math.min(9.0, age * 13)) * mScale),
          size: 10.5 * mScale,
          color: colors.bolt.withValues(
            alpha: (1 - age / 1.5) * 0.9 * nameAlpha,
          ),
        );
      }
    }
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  /// Every frame differs — the clock moved.
  @override
  bool shouldRepaint(GridGrowthPainter old) => true;
}
