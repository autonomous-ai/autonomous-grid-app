import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'grid_canvas.dart';

/// The centre of the picture — **an instrument, not a label.**
///
/// Every other machine on screen is a rounded box with a name on it, and the hub
/// used to be one too: the same loop, a few `isHub ? … : …` branches, a slightly
/// bigger pill. It read exactly like that — a plain circle with a box in it.
///
/// So it is drawn here instead, on its own, and **the frame's whole detail
/// budget is spent on it**. It is the only thing that never leaves the frame:
/// the camera pulls back until a workstation is fifteen pixels wide, and this
/// stays. Everything else is deliberately simpler than it, because the eye needs
/// exactly one place to come back to.
///
/// Eight layers, drawn in the order the methods appear below. The geometry is
/// solved rather than eyeballed — three things share one annulus (§8.6):
///
/// ```
/// plate corner     sqrt(48² + 16.5²)             = 50.8
/// reticle corner   sqrt((48+4.5)² + (16.5+4.5)²) = 56.5
/// tick, inner end  ringR - 2.6 - 5.6             = 59.8
/// ```
///
/// At the ring's old radius of 62 with a 100-wide plate the reticle sat at 60.5
/// and the ticks reached in to 53.5 — they overlapped, and the whole rim read as
/// a smudge. Widening the ring to 68 and pulling the plate in to 96 opens 3.3
/// units between them, which is the entire reason for those two numbers.
class GridHubInstrument {
  GridHubInstrument(this.colors);

  final GridPalette colors;

  /// The ring the whole instrument is laid out around, at a given hub scale.
  ///
  /// Public because the wave wires stop against it (§8.5) and they are drawn in
  /// a different file: `stopAt = ringRadius × 1.28`, where the 1.28 is measured
  /// off *this* number — `68 × 1.28 = 87.0`, and a full seven-lap stack reaches
  /// `68 + 6.5 × Σ0.68ᵏ = 87.0`. Typed twice, the wires would keep stopping
  /// where the ring used to be.
  static double ringRadius(double hubScale) => 68 * hubScale;

  /// **Fixed**, at every zoom. Thinning the scale out as the camera pulls back
  /// (48 → 36) sounds reasonable and is not: it deletes twelve ticks inside a
  /// single frame, mid-scene. They shrink with everything else instead.
  static const int _tickCount = 48;

  final Paint _fill = Paint();
  final Paint _stroke = Paint()..style = PaintingStyle.stroke;
  final Paint _capped = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;

  /// The ticks the sweep is currently over: each one a different alpha, so they
  /// are the only ones that can't be batched into a shared `Path`.
  final Float32List _hotTicks = Float32List(_tickCount * 5);

  late final CanvasText _mark = CanvasText(
    weight: FontWeight.w700,
    tracking: 0,
    fontFamily: Icons.bolt.fontFamily,
    fontFamilyFallback: const [],
    fontPackage: Icons.bolt.fontPackage,
  );
  late final CanvasText _word = CanvasText(
    weight: FontWeight.w700,
    tracking: 1 / 11,
  );

  /// Draws the hub at [centre].
  ///
  /// [charge] is how far the camera has pulled back (0 at the opening framing, 1
  /// at the floor) — the hub gets stronger in step with it rather than through a
  /// staged "charging up" of its own, because the camera is continuous by
  /// construction and a stage is a thing that can be caught starting.
  ///
  /// [filled] is capacity in laps of the ring, one lap per doubling of the pool.
  /// It is worked out by the caller and passed in **already computed**: the tick
  /// marks read `rem` off it, and a draft that derived it down where the laps
  /// are drawn had the scale showing the previous frame's value — a beat late at
  /// exactly the moment a milestone lands.
  void paint(
    Canvas canvas, {
    required Offset centre,
    required double seconds,
    required double scale,
    required double charge,
    required double flash,
    required double grown,
    required double filled,
  }) {
    // Nothing here exists before the viewer's own machine does — the screen
    // opens on a bare page, and a halo with no plate under it would be the one
    // thing on screen that arrived without being switched on.
    if (grown <= 0) return;

    final hs = scale;
    final ringR = ringRadius(hs);
    final laps = math.min(7, filled.floor());
    final rem = filled - filled.floor();

    _glow(canvas, centre, hs, seconds, charge, flash);
    _lens(canvas, centre, ringR);
    _innerArcs(canvas, centre, ringR, grown);
    _track(canvas, centre, ringR);
    _graduations(canvas, centre, ringR, hs, seconds, grown, laps, rem);
    _laps(canvas, centre, ringR, hs, laps, rem);

    final plate = Rect.fromCenter(
      center: centre,
      width: 96 * hs * (0.88 + 0.12 * grown),
      height: 33 * hs * (0.88 + 0.12 * grown),
    );
    _reticle(canvas, plate, hs, charge, flash, grown);
    _plate(canvas, plate, hs, charge, flash, grown);
    _wordmark(canvas, centre, hs, grown);
  }

  /// a. The halo. Breathes faster and reaches further the further back the
  /// camera goes, and jumps on every surge.
  void _glow(
    Canvas canvas,
    Offset centre,
    double hs,
    double seconds,
    double charge,
    double flash,
  ) {
    final breath = 0.5 + 0.5 * math.sin(seconds * (1.25 + charge * 4));
    final radius = (92 + breath * (10 + charge * 20) + flash * 80) * hs;
    final bounds = Rect.fromCircle(center: centre, radius: radius);
    // A shader is modulated by the paint's own alpha, so a colour left over from
    // the last layer to use this `Paint` would quietly scale the whole gradient.
    _fill.color = const Color(0xFFFFFFFF);
    _fill.shader = RadialGradient(
      colors: [
        colors.bolt.withValues(
          alpha: (0.20 + charge * 0.14 + flash * 0.42).clamp(0.0, 1.0),
        ),
        colors.bolt.withValues(alpha: 0),
      ],
    ).createShader(bounds);
    canvas.drawCircle(centre, radius, _fill);
    _fill.shader = null;
  }

  /// b. The ground inside the ring, one step up from the page and dissolving at
  /// the rim.
  ///
  /// Without it the ring is a circle drawn on nothing; with it the ring is the
  /// *edge of something*. Which is also why the colour has to fade its own alpha
  /// to zero rather than fade toward the page — the page is whatever is behind
  /// the canvas, and this has to work over all of it.
  void _lens(Canvas canvas, Offset centre, double ringR) {
    _fill.color = const Color(0xFFFFFFFF);
    _fill.shader = RadialGradient(
      colors: [
        colors.cardBg.withValues(alpha: 0.50),
        colors.cardBg.withValues(alpha: 0.50),
        colors.cardBg.withValues(alpha: 0.30),
        colors.cardBg.withValues(alpha: 0),
      ],
      // The reference gradient runs from 0.1·R to R, so its 0.70 stop lands
      // at 0.73 of a shader that starts at the centre.
      stops: const [0, 0.1, 0.73, 1],
    ).createShader(Rect.fromCircle(center: centre, radius: ringR));
    canvas.drawCircle(centre, ringR, _fill);
    _fill.shader = null;
  }

  /// c. Two arcs inside the ring, and they exist for one measured reason.
  ///
  /// The plate clears the ring by about ten units left and right, but by more
  /// than forty above and below — and that imbalance is the whole of why the
  /// centre used to look empty, however much detail went on around the outside.
  /// At 0.8 the arc has radius 54.4 against a half-plate of 48, so the plate
  /// covers it at the sides; at 0.6 it is 40.8 against a half-height of 16.5, so
  /// it shows above and below. Each one fills exactly the gap that was open, and
  /// nothing else. Drawn before the plate, so the plate cuts them.
  void _innerArcs(Canvas canvas, Offset centre, double ringR, double grown) {
    _stroke
      ..color = colors.hair.withValues(alpha: colors.hair.a * grown * 0.55)
      ..strokeWidth = 1;
    canvas.drawCircle(centre, ringR * 0.6, _stroke);
    canvas.drawCircle(centre, ringR * 0.8, _stroke);
  }

  /// d. The unfilled ring the capacity laps run on.
  ///
  /// At the hairline's own alpha and nothing else: the arcs one layer up state a
  /// factor, this deliberately states none.
  void _track(Canvas canvas, Offset centre, double ringR) {
    _stroke
      ..color = colors.hair
      ..strokeWidth = 2.5;
    canvas.drawCircle(centre, ringR, _stroke);
  }

  /// e. The graduated scale, and the sweep running round it.
  ///
  /// A plain circle is a *shape*; a circle with graduations is an *instrument* —
  /// this one line is most of the difference between the two.
  ///
  /// The ticks carry two readings at once. Gold ones are how far the current lap
  /// has filled, so the arc in [_laps] runs against a real scale instead of
  /// floating on empty ground. Hot ones are wherever the sweep just passed,
  /// which gives the hub a pulse of its own, independent of machines arriving —
  /// and that matters most in the three-second lull and again in the tail, when
  /// nothing else on screen is moving.
  ///
  /// The sweep deliberately has **no track of its own**: a second gold circle,
  /// concentric with the capacity ring and measuring nothing, is noise. It lives
  /// in the graduations instead.
  ///
  /// Forty-eight ticks, three draw calls: one `Path` for the cold ones, one for
  /// the charged ones, and the handful under the sweep drawn individually.
  void _graduations(
    Canvas canvas,
    Offset centre,
    double ringR,
    double hs,
    double seconds,
    double grown,
    int laps,
    double rem,
  ) {
    final outer = ringR - 2.6 * hs;
    final head = (seconds * 0.8) % (2 * math.pi);
    final cold = Path();
    final charged = Path();
    var hot = 0;

    for (var i = 0; i < _tickCount; i++) {
      final t = i / _tickCount;
      final angle = -math.pi / 2 + t * 2 * math.pi;
      final length = (i % 6 == 0 ? 5.6 : 3.0) * hs;
      final dx = math.cos(angle);
      final dy = math.sin(angle);
      final x1 = centre.dx + dx * outer;
      final y1 = centre.dy + dy * outer;
      final x2 = centre.dx + dx * (outer - length);
      final y2 = centre.dy + dy * (outer - length);

      // How long ago the sweep passed this tick, as an angle behind it.
      final delta =
          ((t * 2 * math.pi - head) % (2 * math.pi) + 2 * math.pi) %
          (2 * math.pi);
      final behind = 2 * math.pi - delta;
      final scan = behind < 0.9
          ? math.pow(1 - behind / 0.9, 2).toDouble()
          : 0.0;

      if (scan > 0.02) {
        _hotTicks[hot * 5] = x1;
        _hotTicks[hot * 5 + 1] = y1;
        _hotTicks[hot * 5 + 2] = x2;
        _hotTicks[hot * 5 + 3] = y2;
        _hotTicks[hot * 5 + 4] = scan;
        hot++;
        continue;
      }
      final path = (laps > 0 || t <= rem) ? charged : cold;
      path
        ..moveTo(x1, y1)
        ..lineTo(x2, y2);
    }

    _capped
      ..color = colors.faint.withValues(alpha: grown * 0.42)
      ..strokeWidth = 1.1 * hs;
    canvas.drawPath(cold, _capped);
    _capped
      ..color = colors.bolt.withValues(alpha: grown * 0.62)
      ..strokeWidth = 1.4 * hs;
    canvas.drawPath(charged, _capped);

    _capped.strokeWidth = 1.7 * hs;
    for (var i = 0; i < hot; i++) {
      final scan = _hotTicks[i * 5 + 4];
      _capped.color = colors.boltHot.withValues(
        alpha: (grown * (0.3 + 0.7 * scan)).clamp(0.0, 1.0),
      );
      canvas.drawLine(
        Offset(_hotTicks[i * 5], _hotTicks[i * 5 + 1]),
        Offset(_hotTicks[i * 5 + 2], _hotTicks[i * 5 + 3]),
        _capped,
      );
    }

    _fill.color = colors.boltHot.withValues(alpha: grown * 0.9);
    canvas.drawCircle(
      centre +
          Offset(math.cos(-math.pi / 2 + head), math.sin(-math.pi / 2 + head)) *
              (outer - 2 * hs),
      1.9 * hs,
      _fill,
    );
  }

  /// f. Capacity, as laps of the ring — **one lap per doubling of the pool**.
  ///
  /// Linear would need thirty-odd laps by the time the pool is 21TB, which is no
  /// picture at all. A log scale saturates on its own: the turn ends at 5.91
  /// laps, and the ceiling of 7 is never reached.
  ///
  /// Three things happen together, and all three are needed. The gap between
  /// laps shrinks geometrically, so they gather rather than spread evenly; each
  /// lap is thinner than the one outside it; and each is fainter. A draft drew
  /// them 7px apart at one weight and near enough one brightness, and they piled
  /// into a flat disc. Like this they read as **depth receding**.
  void _laps(
    Canvas canvas,
    Offset centre,
    double ringR,
    double hs,
    int laps,
    double rem,
  ) {
    var offset = 0.0;
    for (var lap = 0; lap <= laps; lap++) {
      if (lap > 0) offset += 6.5 * math.pow(0.68, lap - 1) * hs;
      final outermost = lap == laps && laps > 0;
      final sweep = lap < laps ? 2 * math.pi : rem * 2 * math.pi;
      // A round cap on a zero-length arc is not nothing — it is a gold dot at
      // twelve o'clock, sitting there through the whole of the first second.
      if (sweep <= 0.002) continue;
      _capped
        ..color = (outermost ? colors.boltHot : colors.bolt).withValues(
          alpha: (math.pow(0.74, lap).toDouble() * (outermost ? 1.25 : 1.0))
              .clamp(0.0, 1.0),
        )
        ..strokeWidth = 2.5 * math.pow(0.82, lap).toDouble();
      canvas.drawArc(
        Rect.fromCircle(center: centre, radius: ringR + offset),
        -math.pi / 2,
        sweep,
        false,
        _capped,
      );
    }
  }

  /// g. Four corner brackets, framing the plate without boxing it in. They open
  /// out as the camera pulls back and kick outward on every surge.
  void _reticle(
    Canvas canvas,
    Rect plate,
    double hs,
    double charge,
    double flash,
    double grown,
  ) {
    final out = (4.5 + charge * 2.5 + flash * 5) * hs;
    final arm = 6.5 * hs;
    final box = plate.inflate(out);
    final path = Path();
    for (final sx in const [-1.0, 1.0]) {
      for (final sy in const [-1.0, 1.0]) {
        final x = sx < 0 ? box.left : box.right;
        final y = sy < 0 ? box.top : box.bottom;
        path
          ..moveTo(x - sx * arm, y)
          ..lineTo(x, y)
          ..lineTo(x, y - sy * arm);
      }
    }
    _stroke
      ..color = colors.bolt.withValues(
        alpha: (grown * (0.38 + 0.45 * flash)).clamp(0.0, 1.0),
      )
      ..strokeWidth = 1.2;
    canvas.drawPath(path, _stroke);
  }

  /// h. The plate the wordmark sits on — the one surface in the picture drawn
  /// with actual volume.
  ///
  /// Light from above is the cheapest way to make a flat fill read as a *face*:
  /// a vertical sheen and one specular line along the top edge, both clipped
  /// inside the rounded rect. Without them it is a coloured rectangle.
  ///
  /// **The hard rim is not optional.** The fill is 1.065:1 against the page in
  /// dark and 1.110:1 in light — on its own, in either theme, the plate simply
  /// is not there. The rim is the whole of what makes it exist.
  void _plate(
    Canvas canvas,
    Rect plate,
    double hs,
    double charge,
    double flash,
    double grown,
  ) {
    final shape = RRect.fromRectAndRadius(plate, Radius.circular(10 * hs));

    // Not `Canvas.drawShadow`: that works off elevation and a Z coordinate and
    // gives no direct say over the blur radius, which is the one thing being
    // specified here.
    _fill
      ..color = Colors.black.withValues(alpha: 0.5 * grown)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 16 * hs / 2);
    canvas.drawRRect(shape.shift(Offset(0, 5 * hs)), _fill);
    _fill.maskFilter = null;

    _fill.color = colors.cardBg.withValues(alpha: grown);
    canvas.drawRRect(shape, _fill);

    canvas.save();
    canvas.clipRRect(shape);
    _fill.color = const Color(0xFFFFFFFF);
    _fill.shader = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Colors.white.withValues(alpha: 0.10 * grown),
        Colors.white.withValues(alpha: 0.02 * grown),
        Colors.white.withValues(alpha: 0),
      ],
      stops: const [0, 0.55, 1],
    ).createShader(plate);
    canvas.drawRect(plate, _fill);
    _fill.shader = null;
    _stroke
      ..color = Colors.white.withValues(alpha: 0.26 * grown)
      ..strokeWidth = 1.1;
    canvas.drawLine(
      Offset(plate.left + 10 * hs, plate.top + 0.6),
      Offset(plate.right - 10 * hs, plate.top + 0.6),
      _stroke,
    );
    canvas.restore();

    // Light caught on the edge, not a second border.
    _stroke
      ..color = colors.bolt.withValues(
        alpha: (grown * (0.2 + charge * 0.12 + flash * 0.35)).clamp(0.0, 1.0),
      )
      ..strokeWidth = 3.5;
    canvas.drawRRect(
      RRect.fromRectAndRadius(plate.inflate(2 * hs), Radius.circular(12 * hs)),
      _stroke,
    );

    _stroke
      ..color = (flash > 0.35 ? colors.boltHot : colors.bolt).withValues(
        alpha: grown * 0.92,
      )
      ..strokeWidth = 1.3 + charge * 0.8;
    canvas.drawRRect(shape, _stroke);
  }

  /// i. `⚡ your grid`.
  ///
  /// The bolt is hot gold and the words are brand gold, at different sizes. When
  /// both were one colour at one size the bolt read as a character in a string
  /// rather than as a mark.
  ///
  /// It is drawn from the Material bolt glyph rather than U+26A1: macOS resolves
  /// that codepoint to a colour emoji, which would put a small multicoloured
  /// picture where the one place the brand gold has to be exact is.
  ///
  /// Tracking is most of what separates a wordmark from a run of letters, and
  /// the pair is centred on its **combined** width — centring each half on its
  /// own puts the gap somewhere other than the middle.
  void _wordmark(Canvas canvas, Offset centre, double hs, double grown) {
    if (grown <= 0.01) return;
    final mark = _mark.take(
      String.fromCharCode(Icons.bolt.codePoint),
      size: 13.5 * hs,
      color: colors.boltHot.withValues(alpha: grown),
    );
    final word = _word.take(
      'your grid',
      size: 11 * hs,
      color: colors.bolt.withValues(alpha: grown),
    );
    final gap = 6 * hs;
    // Flutter tracks *after* the final letter too, so the run measures one
    // space wider than it looks.
    final total = mark.width + gap + word.width - 11 * hs / 11;
    final left = centre.dx - total / 2;
    mark.paint(canvas, Offset(left, centre.dy - mark.height / 2));
    word.paint(
      canvas,
      Offset(left + mark.width + gap, centre.dy - word.height / 2),
    );
  }
}
