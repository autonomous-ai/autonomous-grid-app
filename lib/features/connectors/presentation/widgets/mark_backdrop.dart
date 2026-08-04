import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// A [ChangeNotifier] that lets a non-subclass fire it.
///
/// `notifyListeners` is protected, and the thing doing the notifying here is a
/// static method rather than an instance member. Rather than reach around the
/// annotation, this exposes one method that says exactly what it is for.
class ToneBroadcast extends ChangeNotifier {
  void fire() => notifyListeners();
}

/// Which way a logo needs its backdrop to run.
enum MarkTone {
  /// Mostly dark ink. Needs a light plate or it vanishes on a dark card.
  dark,

  /// Mostly light ink. Needs a dark ground; a white plate erases it.
  light,
}

/// Decides the plate a connector's logo should sit on, by looking at the logo.
///
/// **Why this is measured rather than fixed.** The mark used to sit on a white
/// plate unconditionally, on the reasoning that half the directory's logos are
/// dark-on-transparent and would disappear on `#1E1E1E`. That reasoning is
/// right, and incomplete: it is only half the directory. Ten real icons pulled
/// from the registry on 2026-08-04 and composited both ways split **3–3** —
///
/// ```
/// devmatch     on white 18.35:1   on card  1.58:1   -> needs white
/// agentdeals   on white 16.46:1   on card  1.90:1   -> needs white
/// ecomgraph    on white  6.06:1   on card 11.97:1   -> needs the card
/// webforj      on white  4.79:1   on card 10.12:1   -> needs the card
/// ```
///
/// — so a white plate was not a neutral default. It was the wrong ground for
/// half the rows, which is the flatness the report was pointing at: every logo
/// stamped onto the same bright square, several of them washed out on it.
///
/// No single constant can be right for both halves, so the ground is chosen per
/// logo. A light logo gets a dark plate and reads like Claude Desktop's; a dark
/// one keeps the light plate it genuinely needs.
class MarkBackdrop {
  const MarkBackdrop._();

  /// Answers already computed, keyed by URL.
  ///
  /// A list of fifty rebuilds these constantly while scrolling, and decoding an
  /// image to average its pixels is far too expensive to repeat per frame. The
  /// answer is a property of the bytes, so it never goes stale.
  static final Map<String, MarkTone> _cache = {};

  /// A decode already running for this URL, so fifty rows asking at once make
  /// one decode instead of fifty.
  static final Map<String, Future<MarkTone>> _inFlight = {};

  /// What has already been decided for [url], or null if nobody has looked yet.
  ///
  /// Synchronous on purpose: the widget paints with this on the first frame and
  /// only falls back to [toneOf] when it comes back null.
  static MarkTone? cached(String url) => _cache[url];

  /// Look at [bytes] and remember the answer for [url].
  ///
  /// Returns [MarkTone.dark] when the image cannot be decoded — the safe end of
  /// the choice, because a light plate makes *any* logo visible while a dark one
  /// only works for light ink.
  static Future<MarkTone> toneOf(String url, Uint8List bytes) {
    final done = _cache[url];
    if (done != null) return Future.value(done);
    return _inFlight[url] ??= _decode(url, bytes);
  }

  /// Fetch [url] if nobody has, then answer its tone.
  ///
  /// Null when the image could not be fetched or read at all — the caller keeps
  /// whatever it was already drawing rather than flipping to a plate chosen from
  /// no evidence.
  ///
  /// One request per URL for the whole app: `_inFlight` collapses the fifty
  /// simultaneous asks a full grid produces into one, and `_cache` means a
  /// scroll back up asks nothing.
  /// Fires whenever a URL's tone becomes known, so a plate already on screen can
  /// repaint without polling for it.
  ///
  /// One listenable for every mark rather than one per URL: a rebuild is cheap,
  /// there are at most fifty of them, and a map of notifiers would need its own
  /// disposal rules for a value that is written once and never removed.
  static final ToneBroadcast resolved = ToneBroadcast();

  /// Decode [bytes] far enough to average them.
  ///
  /// **SVG lands on the default, and that is accepted rather than solved.**
  /// `instantiateImageCodec` reads bitmaps only, so a vector mark throws here
  /// and keeps [MarkTone.dark] — the light plate, which is safe for any ink.
  /// Rasterising an SVG to measure it would mean a second render pass per mark
  /// for the roughly one in nine that are vectors (measured across the
  /// directory's icons, 2026-08-04), to improve a plate that is already legible.
  static Future<MarkTone> _decode(String url, Uint8List bytes) async {
    var tone = MarkTone.dark;
    try {
      // Small on purpose. This is an average over the whole mark, and a 32px
      // thumbnail carries that average as faithfully as a 1416px original at a
      // two-thousandth of the work — `ecomgraph` above is 1416×1380.
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 32,
        targetHeight: 32,
      );
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      frame.image.dispose();
      codec.dispose();
      if (data != null) tone = _toneOfPixels(data.buffer.asUint8List());
    } on Object {
      // A format Flutter cannot read, or a truncated download. Keep the safe
      // default rather than guessing from the URL.
    }
    _cache[url] = tone;
    _inFlight.remove(url);
    // Tell any plate already painted with the default that its answer is in.
    resolved.fire();
    return tone;
  }

  /// The average luminance of the pixels that are actually painted.
  ///
  /// **Transparent pixels are skipped, and that is the whole trick.** Most of
  /// these logos are a small mark on a transparent field — `social-content` is
  /// 95% transparent — so averaging every pixel would measure the emptiness
  /// around the logo rather than the logo. Only pixels above half alpha count.
  ///
  /// The 0.18 threshold is the midpoint of perceived lightness, not of the 0–255
  /// range: sRGB luminance is already gamma-corrected, so 0.5 would call all but
  /// the brightest logos dark. Against the measured set it separates cleanly —
  /// the dark pair land at 0.029 and 0.060, the light four between 0.19 and 0.70.
  @visibleForTesting
  static MarkTone toneOfPixels(Uint8List rgba) => _toneOfPixels(rgba);

  static MarkTone _toneOfPixels(Uint8List rgba) {
    var painted = 0;
    var total = 0.0;
    for (var i = 0; i + 3 < rgba.length; i += 4) {
      if (rgba[i + 3] < 128) continue;
      painted++;
      total += _luminance(rgba[i], rgba[i + 1], rgba[i + 2]);
    }
    // Nothing opaque at all: an empty or fully transparent image. The light
    // plate is the safe answer, as above.
    if (painted == 0) return MarkTone.dark;
    return total / painted >= 0.18 ? MarkTone.light : MarkTone.dark;
  }

  /// Relative luminance, WCAG's definition — the same one the contrast figures
  /// in this file's doc comment were computed with.
  static double _luminance(int r, int g, int b) =>
      0.2126 * _channel(r) + 0.7152 * _channel(g) + 0.0722 * _channel(b);

  static double _channel(int value) {
    final v = value / 255;
    return v <= 0.03928
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4) as double;
  }
}
