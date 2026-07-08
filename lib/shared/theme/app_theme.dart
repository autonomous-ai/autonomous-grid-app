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
  // Grid brand lightning gold — the live/active ⚡ mark, matching the menu-bar
  // icon and tray bolt (SVG gradient centre) so the same bolt reads everywhere.
  static const brandBolt = Color(0xFFFEC303);

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
    BoxShadow(color: Color(0x1F000000), blurRadius: 8, offset: Offset(0, 2)),
  ];
}

/// Content-card recipe — an opaque dark surface dressed with an indigo accent
/// wash, a tinted rim, an accent glow and a soft corner aura (the web-16 card
/// look). Distinct from [AppGlass] (the shell's frosted blur over the wallpaper):
/// content cards sit on the near-opaque panel where a backdrop blur has nothing
/// to refract, so they earn depth from the accent treatment instead. Indigo
/// palette mirrors web-16's dark tokens. Applied via [GlassCard].
abstract final class AppCard {
  static const accent = Color(0xFF818CF8); // indigo
  static const accentStrong = Color(0xFFA5B4FC);

  static const base = Color(0xFF1B1C1F); // card surface
  static const inset = Color(0xFF16171A); // recessed inner box / list tile
  static const hair = Color(0xFF2E3035); // neutral card rim
  static const insetHair = Color(0x0DFFFFFF); // ~5% white rim on an inset box

  // Indigo accent tints (web-16 dark) — the wash, border and glow all read off
  // these so a card's colour comes from the brand, not a grey frost.
  static const tint10 = Color(0x24A78BFA); // ~14% — base wash / glow / aura
  static const tint18 = Color(0x38818CF8); // ~22% — hero wash
  static const tint25 = Color(0x52818CF8); // ~32% — hero rim

  static const highlightEdge = Color(0x24FFFFFF); // ~14% crisp top hairline

  static const double radius = 18;
  static const double insetRadius = 12;

  /// Soft ambient drop + a faint accent glow that lifts a card off the panel.
  static const List<BoxShadow> shadow = [
    BoxShadow(
      color: Color(0x4D000000),
      blurRadius: 24,
      offset: Offset(0, 10),
      spreadRadius: -6,
    ),
    BoxShadow(
      color: tint10,
      blurRadius: 40,
      offset: Offset(0, 16),
      spreadRadius: -8,
    ),
  ];

  /// The focal (hero) card's stronger lift + accent glow.
  static const List<BoxShadow> heroShadow = [
    BoxShadow(
      color: Color(0x59000000),
      blurRadius: 30,
      offset: Offset(0, 12),
      spreadRadius: -6,
    ),
    BoxShadow(
      color: tint18,
      blurRadius: 38,
      offset: Offset(0, 14),
      spreadRadius: -6,
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
    // Dark, rounded, floating toast that matches the content cards — the M3
    // default snackbar uses `inverseSurface` (a light slab in a dark theme),
    // which read as a bright bar clashing with the app. See [AppCard].
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppCard.base,
      contentTextStyle: const TextStyle(
        color: AppPalette.textPrimary,
        fontSize: 13,
      ),
      actionTextColor: AppCard.accentStrong,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppCard.hair),
      ),
    ),
  );
}
