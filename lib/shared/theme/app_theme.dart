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

/// "Liquid glass" tokens — the translucent frost the chrome and panels wear on
/// top of [AmbientBackground]. Kept neutral-white (like Apple's glass) so the
/// color comes from the lit backdrop behind the panel, not the panel itself.
/// Centralized so every glass surface shares one recipe instead of re-typing
/// BackdropFilter opacities.
abstract final class AppGlass {
  static const double blur = 30; // BackdropFilter sigma for floating glass

  // Frosted body — a top-lit vertical gradient over the blur.
  static const fillTop = Color(0x2EFFFFFF); // ~18% white — catches the light
  static const fillBottom = Color(0x0FFFFFFF); // ~6% white — fades downward
  static const border = Color(0x33FFFFFF); // ~20% white rim

  // Specular highlight — the bright lens edge + soft sheen that makes glass
  // read as glass. Runs along the top of every surface.
  static const edge = Color(0x66FFFFFF); // ~40% crisp top hairline
  static const sheen = Color(0x24FFFFFF); // ~14% soft downward glow

  static const selected = Color(0x38FFFFFF); // selected nav item glass fill
  static const selectedBorder = Color(0x4DFFFFFF); // its brighter rim

  // Content panel — nearly opaque so dense UI stays readable, yet still lets a
  // whisper of the backdrop bleed through at the edges.
  static const panelTop = Color(0xF01F1F26);
  static const panelBottom = Color(0xF014141A);

  static const panelFill = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [panelTop, panelBottom],
  );

  /// Soft drop shadow that lifts a floating panel off the backdrop.
  static const shadow = <BoxShadow>[
    BoxShadow(
      color: Color(0x40000000),
      blurRadius: 28,
      offset: Offset(0, 14),
      spreadRadius: -8,
    ),
    BoxShadow(
      color: Color(0x1F000000),
      blurRadius: 8,
      offset: Offset(0, 2),
    ),
  ];
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
