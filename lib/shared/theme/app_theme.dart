import 'package:flutter/material.dart';

/// Tailscale-inspired dark palette. Centralized so every pane reads the same
/// surfaces/accents instead of re-typing hex literals.
abstract final class AppPalette {
  static const windowBg = Color(0xFF1B1B1D); // app background (near-black)
  static const panelBg = Color(0xFF202023); // sidebar / list column
  static const cardBg = Color(0xB328282F); // detail cards, search field (glass)
  static const cardBgHover = Color(0xC22F2F38);
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

  // Content panel — a real frosted pane: translucent enough that the blurred
  // wallpaper shows through ("trong trong"), dark enough that dense text on top
  // stays readable. Slightly darker at the bottom for depth.
  static const panelTop = Color(0x8C181820); // ~55%
  static const panelBottom = Color(0x9E121219); // ~62%

  static const panelFill = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [panelTop, panelBottom],
  );

  /// A recessed well inside a glass panel (e.g. the grid list column) — a faint
  /// darken that sets the column back without turning it into an opaque slab, so
  /// it still reads as frosted glass over the wallpaper.
  static const recess = Color(0x14000000); // ~8% black over the panel glass

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
