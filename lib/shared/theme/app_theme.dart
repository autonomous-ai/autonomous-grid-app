import 'package:flutter/material.dart';

/// Tailscale-inspired dark palette. Centralized so every pane reads the same
/// surfaces/accents instead of re-typing hex literals.
abstract final class AppPalette {
  static const windowBg = Color(0xFF1B1B1D); // app background (near-black)
  static const panelBg = Color(0xFF202023); // sidebar / list column
  static const cardBg = Color(0xFF26262A); // detail cards, search field
  static const cardBgHover = Color(0xFF2E2E33);
  static const divider = Color(0xFF313136);

  static const accent = Color(0xFF4C6EF5); // toggle / selected row (blue)
  static const accentMuted = Color(0xFF2F4FB8);
  // "Owner" badge — a teal that stays legible on the blue selected row, where
  // the accent blue would vanish into the background.
  static const teal = Color(0xFF2DD4BF);
  static const online = Color(0xFF34C759); // green "connected" dot
  static const warn = Color(0xFFFFB020); // expiring soon
  static const offline = Color(0xFF6B6B72); // grey dot

  static const textPrimary = Color(0xFFE6E6EA);
  static const textSecondary = Color(0xFF9A9AA3);
  static const textFaint = Color(0xFF6E6E76);
}

/// The single dark theme the app ships with — Tailscale-style.
ThemeData buildAppTheme() {
  const scheme = ColorScheme.dark(
    primary: AppPalette.accent,
    onPrimary: Colors.white,
    secondary: AppPalette.accent,
    surface: AppPalette.windowBg,
    onSurface: AppPalette.textPrimary,
    onSurfaceVariant: AppPalette.textSecondary,
    surfaceContainerHighest: AppPalette.cardBg,
    outline: AppPalette.divider,
    error: Color(0xFFFF6B6B),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppPalette.windowBg,
    canvasColor: AppPalette.windowBg,
    dividerColor: AppPalette.divider,
    dividerTheme: const DividerThemeData(
      color: AppPalette.divider,
      thickness: 1,
      space: 1,
    ),
    splashFactory: InkRipple.splashFactory,
    textTheme: const TextTheme().apply(
      bodyColor: AppPalette.textPrimary,
      displayColor: AppPalette.textPrimary,
    ),
    iconTheme: const IconThemeData(color: AppPalette.textSecondary, size: 18),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.all(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? AppPalette.accent
            : AppPalette.offline,
      ),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: AppPalette.cardBg,
      hintStyle: const TextStyle(color: AppPalette.textFaint),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppPalette.divider),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppPalette.divider),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppPalette.accent),
      ),
    ),
  );
}
