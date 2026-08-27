import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';

/// The colours the welcome picture is drawn from, resolved once per build.
///
/// A `CustomPainter` runs outside the widget that watched the theme, so it can't
/// read `AppPalette` itself and follow a Light/Dark flip — the tokens are
/// getters that resolve at paint time and have nothing to rebuild them. Handing
/// the resolved set in is what makes the picture change with the app.
class GridPalette {
  const GridPalette({
    required this.cardBg,
    required this.hair,
    required this.bolt,
    required this.boltHot,
    required this.online,
    required this.label,
    required this.faint,
  });

  /// Reads the live tokens. Call from a `build` that has already called
  /// [AppTheme.watch].
  factory GridPalette.resolve() => GridPalette(
    cardBg: AppPalette.cardBg,
    hair: AppTheme.pick(const Color(0x26000000), const Color(0x33FFFFFF)),
    bolt: AppPalette.brandBolt,
    boltHot: AppTheme.pick(const Color(0xFF9A6B00), const Color(0xFFFFD98A)),
    online: AppPalette.online,
    label: AppPalette.textSecondary,
    faint: AppPalette.textFaint,
  );

  /// Every pill on screen, from the hub's plate to a 4px rack.
  final Color cardBg;

  /// The rim that keeps a pill from dissolving into the page.
  ///
  /// **Carries its own alpha**, so every factor the spec puts on a hairline
  /// multiplies *that*, not 1. Forgetting it is how a draft ended up stroking
  /// 300 links at an effective 1.8% — drawn, paid for, invisible.
  ///
  /// Which is also why this is 20% / 15% rather than `AppCard.insetHair`'s
  /// 7.8% / 5.9%. That token is built to part two solid surfaces at full
  /// strength; here almost every hairline is multiplied by a depth factor as
  /// low as 0.25 before it is drawn. Measured on the real page, the token
  /// version puts a wave pill's rim at **1.109:1 dark / 1.066:1 light** and the
  /// hub's ring track at 1.276 / 1.137 — drawn, paid for, invisible, the exact
  /// failure this is warned about. At 20% / 15% the same rims land at
  /// 1.339 / 1.180 and the track at 1.896 / 1.407. 20% is also what the
  /// reference implementation used.
  final Color hair;

  /// The brand gold. Every accent in the animation is this one colour.
  final Color bolt;

  /// The same gold, hot: reserved for the instant a machine lands and for the
  /// flash at each surge. Not a second accent — the same one at temperature.
  ///
  /// Hotter means *more present*, and which direction that lies in depends on
  /// the page. In dark it is brighter (`#FFD98A` over `#E0A93B`). In light it
  /// has to be **deeper**, not lighter: the spec's `#E8A93B` is lighter than
  /// brand gold, so on a white page a tick the sweep had just lit measured
  /// **1.003:1** against a resting one — the hub's second reading simply gone,
  /// and the outermost capacity lap the faintest of the stack. `#9A6B00` puts
  /// the hot/resting step at 1.590:1 in light against dark's 1.569:1, so the
  /// same beat reads the same in both.
  final Color boltHot;

  final Color online;
  final Color label;
  final Color faint;
}

/// Text laid out once and kept between frames.
///
/// A `TextPainter` bakes size *and* colour into its layout, so the honest cache
/// key is (string, size, colour) — which at the peak of the last wave would mean
/// a fresh layout for every receipt, every frame. Two things bound it instead:
/// every label of one kind shares a single scale, so the whole bucket is thrown
/// away when that scale moves more than 2%; and alpha — the only part that
/// really moves per shape — is quantised to sixteen steps.
///
/// What is left is a few dozen live entries where there were ~60 layouts a
/// frame, and nothing the eye can tell apart from the exact value.
class CanvasText {
  CanvasText({
    required this.weight,
    this.tracking = -0.009,
    String? fontFamily,
    List<String>? fontFamilyFallback,
    this.fontPackage,
  }) : fontFamily = fontFamily ?? AppFont.mono,
       fontFamilyFallback = fontFamilyFallback ?? AppFont.monoFallback;

  final FontWeight weight;

  /// Letter spacing as a **fraction of the font size**, not a pixel figure.
  /// Every size here is a multiple of a scale that moves all scene long, and
  /// tracking that stayed put would tighten as the type grew and open up as it
  /// shrank — the one thing tracking must never do.
  final double tracking;

  /// Defaults to the app's mono stack, because everything drawn on this canvas
  /// is a readout: machine names, `+48GB` receipts, the wordmark. A proportional
  /// face turns a row of figures into a row of different-width figures, and the
  /// wordmark's tracking was worked out against mono's tighter setting.
  ///
  /// Overridden only to draw an icon glyph (`Icons.bolt`).
  final String fontFamily;
  final List<String> fontFamilyFallback;
  final String? fontPackage;

  final Map<(String, int), TextPainter> _laid = {};
  double _size = 0;
  int _rgb = -1;

  /// A laid-out painter for [text], at the bucket's size and a quantised alpha.
  TextPainter take(String text, {required double size, required Color color}) {
    final rgb = color.toARGB32() & 0x00FFFFFF;
    if (rgb != _rgb || (size - _size).abs() > _size * 0.02) {
      _laid.clear();
      _size = size;
      _rgb = rgb;
    }
    final step = (color.a * 15).round().clamp(0, 15);
    return _laid.putIfAbsent(
      (text, step),
      () => TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: color.withValues(alpha: step / 15),
            fontSize: _size,
            fontWeight: weight,
            letterSpacing: _size * tracking,
            fontFamily: fontFamily,
            fontFamilyFallback: fontFamilyFallback,
            package: fontPackage,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(),
    );
  }

  /// Draws [text] centred on [at]. Skips the layout entirely once it is too
  /// faint to see — the last wave asks for hundreds of these.
  void paintCentred(
    Canvas canvas,
    String text,
    Offset at, {
    required double size,
    required Color color,
  }) {
    if (color.a <= 0.02) return;
    final painter = take(text, size: size, color: color);
    painter.paint(canvas, at - Offset(painter.width / 2, painter.height / 2));
  }
}
