import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';

/// Overlord-specific visual tokens, scoped to this feature so the dashboard's
/// telemetry look (mono type, teal "live" accent, load-level coloring) lives in
/// one place instead of being re-typed per widget. Surfaces still come from the
/// shared [AppPalette] so the dashboard sits flush with the rest of the app.
abstract final class OverlordTokens {
  /// The single typeface for every number/label on the dashboard.
  static const mono = 'monospace';

  /// "live" pulse + low-load sparklines. A teal that reads as healthy/idle.
  static const accent = Color(0xFF2DD4BF);

  /// Load bands for utilisation / memory bars and their sparklines.
  static const normal = Color(0xFF2DD4BF); // healthy / idle
  static const warn = Color(0xFFFFB020); // getting full
  static const critical = Color(0xFFFF5C7C); // near-saturated (pink-red)

  /// Color a 0–100 load reading by band. Tuned so a screenshot-style fleet
  /// (71% unified mem → teal, ~89% → amber, 92–96% VRAM → red) reads right.
  static Color loadColor(double percent) {
    if (percent >= 90) return critical;
    if (percent >= 75) return warn;
    return normal;
  }

  // — shared mono text styles, sized to the dashboard's density —

  static TextStyle get cardTitle => TextStyle(
    fontFamily: mono,
    fontSize: 14,
    fontWeight: FontWeight.w700,
    color: AppPalette.textPrimary,
  );

  static TextStyle get sublabel => TextStyle(
    fontFamily: mono,
    fontSize: 11,
    letterSpacing: 0.6,
    color: AppPalette.textFaint,
  );

  static TextStyle get meta => TextStyle(
    fontFamily: mono,
    fontSize: 11.5,
    color: AppPalette.textSecondary,
  );

  static TextStyle get processLine => TextStyle(
    fontFamily: mono,
    fontSize: 11,
    color: AppPalette.textFaint,
  );
}
