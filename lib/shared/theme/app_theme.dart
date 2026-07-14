import 'package:flutter/material.dart';

/// The app's light palette — a warm paper white with near-black ink, the way a
/// desktop chat app should read at a desk in daylight. Centralized so every pane
/// reads the same surfaces/accents instead of re-typing hex literals.
///
/// The app ships light only: it's a chat window people keep open next to their
/// editor, and a single, consistent surface is easier to keep legible (and to
/// contrast-check, §11) than two half-tuned ones.
abstract final class AppPalette {
  static const windowBg = Color(0xFFFEFEFD); // the conversation / content area
  static const panelBg = Color(0xFFF4F4F2); // sidebar column (warm paper)
  static const cardBg = Color(0xFFF4F4F2); // input fills, quiet cards
  static const cardBgHover = Color(0xFFEDEDEB);
  static const divider = Color(0x12000000);

  static const accent = Color(0xFF2F5BEA); // primary action / selection
  static const accentMuted = Color(
    0xFF3550C8,
  ); // avatar fill (white text on it)
  // "Owner" badge — a teal dark enough to stay legible on white.
  static const teal = Color(0xFF0F766E);
  static const online = Color(0xFF15803D); // green "connected" dot
  static const warn = Color(0xFFB45309); // expiring soon
  static const offline = Color(0xFFA3A29C); // grey dot
  // Grid brand lightning gold — the live/active ⚡ mark, matching the menu-bar
  // icon and tray bolt. Deepened from the tray gradient so it holds contrast on
  // a white surface.
  static const brandBolt = Color(0xFFC98A00);

  static const textPrimary = Color(0xFF1A1A18);
  static const textSecondary = Color(0xFF62615B);
  static const textFaint = Color(0xFF8E8D86);
}

/// Surface tokens for the app's chrome — the sidebar's rows, the composer card,
/// a recessed list column. On a white app depth comes from a hairline rim and a
/// soft shadow, not from a blur (there's nothing behind it to refract).
/// Centralized so every raised surface shares one recipe.
abstract final class AppSurface {
  /// The sidebar row you're on.
  static const selectedFill = Color(0x0D000000); // ~5% black

  /// The sidebar row under the pointer — lighter than [selectedFill], so hover
  /// never reads as "selected".
  static const hoverFill = Color(0x08000000); // ~3% black

  /// A recessed well inside a panel (e.g. the grid list column) — a faint darken
  /// that sets the column back without drawing a hard box around it.
  static const recess = Color(0x08000000);

  /// Soft drop shadow that lifts a floating surface (the composer) off the page.
  static const shadow = <BoxShadow>[
    BoxShadow(
      color: Color(0x14000000),
      blurRadius: 24,
      offset: Offset(0, 10),
      spreadRadius: -10,
    ),
    BoxShadow(color: Color(0x0A000000), blurRadius: 4, offset: Offset(0, 1)),
  ];

  /// A quieter lift for the composer. It should feel docked, not like a card
  /// hovering high above the transcript.
  static const composerShadow = <BoxShadow>[
    BoxShadow(
      color: Color(0x16000000),
      blurRadius: 18,
      offset: Offset(0, 7),
      spreadRadius: -8,
    ),
    BoxShadow(color: Color(0x0A000000), blurRadius: 3, offset: Offset(0, 1)),
  ];
}

/// Translucent Codex-like chrome surfaces: white fills, soft rims, and almost
/// flat shadows. Kept separate from [AppCard] because these surfaces are chrome,
/// not dense content cards.
abstract final class AppGlass {
  static const sidebarFill = Color(0xEEF5F5F3);
  static const surfaceFill = Color(0xFAFFFFFF);
  static const surfaceHoverFill = Color(0xFFFDFDFC);
  static const hair = Color(0x0D000000);
  static const bubbleFill = Color(0xFFF3F3F1);

  static const shadow = <BoxShadow>[
    BoxShadow(
      color: Color(0x18000000),
      blurRadius: 24,
      offset: Offset(0, 11),
      spreadRadius: -10,
    ),
    BoxShadow(color: Color(0x0A000000), blurRadius: 4, offset: Offset(0, 1)),
  ];

  static const cardShadow = <BoxShadow>[
    BoxShadow(
      color: Color(0x18000000),
      blurRadius: 18,
      offset: Offset(0, 8),
      spreadRadius: -9,
    ),
    BoxShadow(color: Color(0x0A000000), blurRadius: 3, offset: Offset(0, 1)),
  ];
}

/// Content-card recipe — a white surface with a hairline rim and a soft lift.
/// Distinct from [AppSurface] (the chrome): cards carry dense content, so they stay
/// quiet and let the text do the work. Applied via [GlassCard].
abstract final class AppCard {
  static const accent = AppPalette.accent;
  static const accentStrong = Color(0xFF1E40AF);

  static const base = Color(0xFFFFFFFF); // card surface
  static const inset = Color(0xFFF7F7F5); // recessed inner box / list tile
  static const hair = AppPalette.divider; // card rim
  static const insetHair = Color(0x0F000000); // rim on an inset box

  // Accent tints — used sparingly, for the focal card's wash and rim.
  static const tint10 = Color(0x0A2F5BEA);
  static const tint18 = Color(0x142F5BEA);
  static const tint25 = Color(0x332F5BEA);

  static const highlightEdge = Color(0x0A000000);

  static const double radius = 18;
  static const double insetRadius = 12;

  /// Soft ambient drop that lifts a card off the page.
  static const List<BoxShadow> shadow = [
    BoxShadow(
      color: Color(0x12000000),
      blurRadius: 20,
      offset: Offset(0, 8),
      spreadRadius: -8,
    ),
  ];

  /// The focal (hero) card's stronger lift.
  static const List<BoxShadow> heroShadow = [
    BoxShadow(
      color: Color(0x1A000000),
      blurRadius: 28,
      offset: Offset(0, 12),
      spreadRadius: -8,
    ),
    BoxShadow(
      color: tint18,
      blurRadius: 32,
      offset: Offset(0, 10),
      spreadRadius: -8,
    ),
  ];
}

/// The single light theme the app ships with.
ThemeData buildAppTheme() {
  const scheme = ColorScheme.light(
    primary: AppPalette.accent,
    onPrimary: Colors.white,
    secondary: AppPalette.accent,
    surface: AppPalette.windowBg,
    onSurface: AppPalette.textPrimary,
    onSurfaceVariant: AppPalette.textSecondary,
    surfaceContainerHighest: AppPalette.cardBg,
    outline: AppPalette.divider,
    outlineVariant: AppPalette.divider,
    error: Color(0xFFB3261E),
  );

  final textTheme = _appTextTheme();

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
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
    textTheme: textTheme,
    primaryTextTheme: textTheme,
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
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(Colors.white),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(8),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      width: 520,
      backgroundColor: Colors.white,
      contentTextStyle: const TextStyle(
        color: AppPalette.textPrimary,
        fontSize: 13.5,
        fontWeight: FontWeight.w600,
      ),
      actionTextColor: AppPalette.accent,
      closeIconColor: AppPalette.textSecondary,
      elevation: 10,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
    ),
  );
}

TextTheme _appTextTheme() {
  const base = TextStyle(
    fontFamily: '.AppleSystemUIFont',
    fontFamilyFallback: ['SF Pro Text', 'Helvetica Neue', 'Arial'],
    color: AppPalette.textPrimary,
    letterSpacing: 0,
    height: 1.34,
    fontWeight: FontWeight.w400,
  );

  return TextTheme(
    displayLarge: base.copyWith(fontSize: 57, fontWeight: FontWeight.w600),
    displayMedium: base.copyWith(fontSize: 45, fontWeight: FontWeight.w600),
    displaySmall: base.copyWith(fontSize: 36, fontWeight: FontWeight.w600),
    headlineLarge: base.copyWith(fontSize: 32, fontWeight: FontWeight.w600),
    headlineMedium: base.copyWith(fontSize: 29, fontWeight: FontWeight.w600),
    headlineSmall: base.copyWith(fontSize: 25, fontWeight: FontWeight.w600),
    titleLarge: base.copyWith(fontSize: 22, fontWeight: FontWeight.w600),
    titleMedium: base.copyWith(fontSize: 17, fontWeight: FontWeight.w600),
    titleSmall: base.copyWith(fontSize: 14.5, fontWeight: FontWeight.w600),
    bodyLarge: base.copyWith(fontSize: 16.5),
    bodyMedium: base.copyWith(fontSize: 15),
    bodySmall: base.copyWith(fontSize: 13.5, color: AppPalette.textSecondary),
    labelLarge: base.copyWith(fontSize: 14.5, fontWeight: FontWeight.w600),
    labelMedium: base.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
    labelSmall: base.copyWith(fontSize: 12, fontWeight: FontWeight.w600),
  );
}
