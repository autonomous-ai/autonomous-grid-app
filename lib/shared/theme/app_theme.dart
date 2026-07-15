import 'package:flutter/material.dart';

/// The app's live brightness — the single source of truth the color tokens below
/// resolve against. It is *not* read from the platform directly: [_BrightnessSync]
/// (in `grid_app.dart`) sets it from `Theme.of(context).brightness`, i.e. the
/// brightness Material actually resolved after `ThemeMode.system` is applied, so
/// the tokens always match what the framework rendered.
///
/// Every `AppPalette`/`AppSurface`/`AppGlass`/`AppCard` member is a getter that
/// switches on this, so a call site like `color: AppPalette.windowBg` follows the
/// theme with no change to the call site.
abstract final class AppTheme {
  static final ValueNotifier<Brightness> brightness = ValueNotifier(
    Brightness.light,
  );

  static bool get isDark => brightness.value == Brightness.dark;

  /// Pick between a light and a dark value for the current brightness.
  static T pick<T>(T light, T dark) => isDark ? dark : light;

  /// Registers the calling widget to rebuild whenever [brightness] flips, and
  /// returns the current value.
  ///
  /// The color tokens read [brightness] `.value` directly — a plain field read
  /// the element tree can't see — so a widget that only reads tokens has no
  /// tracked reason to rebuild when the theme changes. Worse, the app is full of
  /// `const` chrome (`const AppSidebar()`, `const _MainShellBody()`), and a
  /// `const` child is reference-identical across a parent's rebuild, so Flutter
  /// short-circuits it: rebuilding from the top never reaches the sidebar, and it
  /// stays on the old palette until something *else* (a Riverpod change from
  /// clicking a row) happens to rebuild it.
  ///
  /// Calling this at the top of a chrome widget's `build` fixes that at the root:
  /// it depends on the [_BrightnessScope] inherited widget, whose notifier is
  /// [brightness]. An `InheritedNotifier` marks its dependents dirty *directly*
  /// when the notifier fires — it doesn't rebuild through the widget tree — so
  /// every `const` boundary in between is irrelevant. This is exactly how
  /// `Theme.of(context)` makes a widget follow the theme.
  static Brightness watch(BuildContext context) {
    context.dependOnInheritedWidgetOfExactType<_BrightnessScope>();
    return brightness.value;
  }
}

/// Wraps the app so any descendant that calls [AppTheme.watch] rebuilds when the
/// brightness flips — regardless of the `const` widgets in between. Mount it once,
/// high in the tree (see `grid_app.dart`).
class BrightnessScope extends StatelessWidget {
  const BrightnessScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return _BrightnessScope(notifier: AppTheme.brightness, child: child);
  }
}

class _BrightnessScope extends InheritedNotifier<ValueNotifier<Brightness>> {
  const _BrightnessScope({required super.notifier, required super.child});
}

/// The app's palette — a warm paper white with near-black ink in light, a deep
/// charcoal with off-white ink in dark (the design-system "Codex" direction).
/// Centralized so every pane reads the same surfaces/accents instead of re-typing
/// hex literals, and resolves per [AppTheme.brightness].
abstract final class AppPalette {
  // the conversation / content area — pure white in light, like Codex.
  static Color get windowBg =>
      AppTheme.pick(const Color(0xFFFFFFFF), const Color(0xFF0A0A0A));

  // sidebar column — a barely-there cool grey (Codex keeps the rail almost white,
  // set apart by a hairline, not a tone) / charcoal panel in dark.
  static Color get panelBg =>
      AppTheme.pick(const Color(0xFFF9F9F8), const Color(0xFF141414));

  // input fills, quiet cards
  static Color get cardBg =>
      AppTheme.pick(const Color(0xFFF3F3F2), const Color(0xFF1E1E1E));

  static Color get cardBgHover =>
      AppTheme.pick(const Color(0xFFECECEA), const Color(0xFF252525));

  // A hairline separator. Light: a faint cool black; dark: a faint white — a
  // black divider would vanish on charcoal.
  static Color get divider =>
      AppTheme.pick(const Color(0x0F000000), const Color(0x14FFFFFF));

  // primary action / selection — the same indigo reads well on both surfaces.
  static const accent = Color(0xFF2F5BEA);

  // avatar fill (white text on it); a touch brighter in dark for contrast.
  static Color get accentMuted =>
      AppTheme.pick(const Color(0xFF3550C8), const Color(0xFF4E6BF0));

  // "Owner" badge — a teal that stays legible on either surface.
  static Color get teal =>
      AppTheme.pick(const Color(0xFF0F766E), const Color(0xFF2DD4BF));

  // green "connected" dot
  static Color get online =>
      AppTheme.pick(const Color(0xFF15803D), const Color(0xFF3FB950));

  // expiring soon
  static Color get warn =>
      AppTheme.pick(const Color(0xFFB45309), const Color(0xFFFFB020));

  // grey dot
  static Color get offline =>
      AppTheme.pick(const Color(0xFFA3A29C), const Color(0xFF6E6E6E));

  // Grid brand lightning gold — the live/active ⚡ mark, matching the tray bolt.
  static Color get brandBolt =>
      AppTheme.pick(const Color(0xFFC98A00), const Color(0xFFE0A93B));

  static Color get textPrimary =>
      AppTheme.pick(const Color(0xFF1A1A18), const Color(0xFFF5F5F5));

  static Color get textSecondary =>
      AppTheme.pick(const Color(0xFF62615B), const Color(0xFFA8A8A2));

  static Color get textFaint =>
      AppTheme.pick(const Color(0xFF8E8D86), const Color(0xFF6E6E68));
}

/// Surface tokens for the app's chrome — the sidebar's rows, the composer card,
/// a recessed list column. Depth comes from a hairline rim and a soft shadow; the
/// overlays flip from black (on light) to white (on dark) so a hover/selection is
/// visible on either surface.
abstract final class AppSurface {
  /// The sidebar row you're on.
  static Color get selectedFill =>
      AppTheme.pick(const Color(0x0D000000), const Color(0x14FFFFFF));

  /// The sidebar row under the pointer — lighter than [selectedFill], so hover
  /// never reads as "selected".
  static Color get hoverFill =>
      AppTheme.pick(const Color(0x07000000), const Color(0x0DFFFFFF));

  /// A whisper of the accent, washed under the rail's primary action ("New
  /// chat") so it invites the click without hardening into a button. Kept faint
  /// (~8% in light, a touch stronger in dark so it reads on charcoal).
  static Color get accentWash =>
      AppTheme.pick(const Color(0x142F5BEA), const Color(0x242F5BEA));

  /// The same wash a step stronger, for the primary action under the pointer —
  /// so hovering it still reads as a change without ever looking "selected".
  static Color get accentWashHover =>
      AppTheme.pick(const Color(0x1F2F5BEA), const Color(0x332F5BEA));

  /// A recessed well inside a panel (e.g. the grid list column).
  static Color get recess =>
      AppTheme.pick(const Color(0x08000000), const Color(0x0FFFFFFF));

  /// Soft drop shadow that lifts a floating surface (the composer) off the page.
  /// Deeper/darker in dark mode where a light lift would look like a glow.
  static List<BoxShadow> get shadow => AppTheme.pick(
    const [
      BoxShadow(
        color: Color(0x14000000),
        blurRadius: 24,
        offset: Offset(0, 10),
        spreadRadius: -10,
      ),
      BoxShadow(color: Color(0x0A000000), blurRadius: 4, offset: Offset(0, 1)),
    ],
    const [
      BoxShadow(
        color: Color(0x66000000),
        blurRadius: 24,
        offset: Offset(0, 10),
        spreadRadius: -10,
      ),
      BoxShadow(color: Color(0x40000000), blurRadius: 4, offset: Offset(0, 1)),
    ],
  );

  /// The composer's lift — Codex gives its input a soft shadow that spreads wide
  /// and low so the box clearly floats over the transcript. Two layers: a broad
  /// ambient pool plus a tighter contact shadow right under the rim.
  static List<BoxShadow> get composerShadow => AppTheme.pick(
    const [
      BoxShadow(
        color: Color(0x1F000000),
        blurRadius: 28,
        offset: Offset(0, 10),
        spreadRadius: -6,
      ),
      BoxShadow(
        color: Color(0x14000000),
        blurRadius: 8,
        offset: Offset(0, 2),
        spreadRadius: -2,
      ),
    ],
    const [
      BoxShadow(
        color: Color(0x80000000),
        blurRadius: 30,
        offset: Offset(0, 12),
        spreadRadius: -6,
      ),
      BoxShadow(
        color: Color(0x4D000000),
        blurRadius: 10,
        offset: Offset(0, 3),
        spreadRadius: -3,
      ),
    ],
  );
}

/// Translucent Codex-like chrome surfaces used behind a backdrop blur (the
/// sidebar, the top bar, floating pills). Fills are semi-transparent so the blur
/// shows through; kept separate from [AppCard] because these surfaces are chrome,
/// not dense content cards.
abstract final class AppGlass {
  // Near-opaque so the rail reads as a calm flat surface, not a frosted panel.
  static Color get sidebarFill =>
      AppTheme.pick(const Color(0xF7F9F9F8), const Color(0xF01A1A1A));

  // Pills/menus are solid white in Codex (their softness comes from the rim and
  // a whisper of shadow, not from translucency).
  static Color get surfaceFill =>
      AppTheme.pick(const Color(0xFFFFFFFF), const Color(0xFF202020));

  static Color get surfaceHoverFill =>
      AppTheme.pick(const Color(0xFFF7F7F6), const Color(0xFF272727));

  static Color get hair =>
      AppTheme.pick(const Color(0x14000000), const Color(0x1FFFFFFF));

  /// A more present rim for the surfaces that should read as *lifted* — the
  /// composer, above all. The plain [hair] disappears into a white pane; this one
  /// is a clear soft grey (~#DADADA on white) so the input keeps a visible edge
  /// like Codex, without hardening into a boxy outline.
  static Color get lift =>
      AppTheme.pick(const Color(0x2E000000), const Color(0x2EFFFFFF));

  static Color get bubbleFill =>
      AppTheme.pick(const Color(0xFFF3F3F1), const Color(0xFF242424));

  static List<BoxShadow> get shadow => AppTheme.pick(
    const [
      BoxShadow(
        color: Color(0x14000000),
        blurRadius: 16,
        offset: Offset(0, 6),
        spreadRadius: -6,
      ),
      BoxShadow(color: Color(0x0A000000), blurRadius: 2, offset: Offset(0, 1)),
    ],
    const [
      BoxShadow(
        color: Color(0x66000000),
        blurRadius: 18,
        offset: Offset(0, 7),
        spreadRadius: -7,
      ),
      BoxShadow(color: Color(0x33000000), blurRadius: 3, offset: Offset(0, 1)),
    ],
  );

  // A whisper — the soft, tight lift Codex gives its floating pills and menus,
  // not a big ambient drop.
  static List<BoxShadow> get cardShadow => AppTheme.pick(
    const [
      BoxShadow(
        color: Color(0x0F000000),
        blurRadius: 8,
        offset: Offset(0, 3),
        spreadRadius: -3,
      ),
      BoxShadow(color: Color(0x08000000), blurRadius: 1, offset: Offset(0, 1)),
    ],
    const [
      BoxShadow(
        color: Color(0x59000000),
        blurRadius: 10,
        offset: Offset(0, 4),
        spreadRadius: -4,
      ),
    ],
  );
}

/// Content-card recipe — a surface with a hairline rim and a soft lift. Distinct
/// from [AppSurface] (the chrome): cards carry dense content, so they stay quiet
/// and let the text do the work. Applied via [GlassCard].
abstract final class AppCard {
  static const accent = AppPalette.accent;
  static Color get accentStrong =>
      AppTheme.pick(const Color(0xFF1E40AF), const Color(0xFF5C7CFF));

  // card surface
  static Color get base =>
      AppTheme.pick(const Color(0xFFFFFFFF), const Color(0xFF1E1E1E));

  // recessed inner box / list tile
  static Color get inset =>
      AppTheme.pick(const Color(0xFFF7F7F5), const Color(0xFF181818));

  static Color get hair => AppPalette.divider; // card rim
  static Color get insetHair =>
      AppTheme.pick(const Color(0x0F000000), const Color(0x14FFFFFF));

  // Accent tints — used sparingly, for the focal card's wash and rim. Slightly
  // stronger in dark so the wash reads on charcoal.
  static Color get tint10 =>
      AppTheme.pick(const Color(0x0A2F5BEA), const Color(0x1A2F5BEA));
  static Color get tint18 =>
      AppTheme.pick(const Color(0x142F5BEA), const Color(0x282F5BEA));
  static Color get tint25 =>
      AppTheme.pick(const Color(0x332F5BEA), const Color(0x422F5BEA));

  static Color get highlightEdge =>
      AppTheme.pick(const Color(0x0A000000), const Color(0x1FFFFFFF));

  static const double radius = 18;
  static const double insetRadius = 12;

  /// Soft ambient drop that lifts a card off the page.
  static List<BoxShadow> get shadow => AppTheme.pick(
    const [
      BoxShadow(
        color: Color(0x12000000),
        blurRadius: 20,
        offset: Offset(0, 8),
        spreadRadius: -8,
      ),
    ],
    const [
      BoxShadow(
        color: Color(0x66000000),
        blurRadius: 20,
        offset: Offset(0, 8),
        spreadRadius: -8,
      ),
    ],
  );

  /// The focal (hero) card's stronger lift.
  static List<BoxShadow> get heroShadow => AppTheme.pick(
    [
      const BoxShadow(
        color: Color(0x1A000000),
        blurRadius: 28,
        offset: Offset(0, 12),
        spreadRadius: -8,
      ),
      BoxShadow(
        color: tint18,
        blurRadius: 32,
        offset: const Offset(0, 10),
        spreadRadius: -8,
      ),
    ],
    [
      const BoxShadow(
        color: Color(0x73000000),
        blurRadius: 28,
        offset: Offset(0, 12),
        spreadRadius: -8,
      ),
      BoxShadow(
        color: tint18,
        blurRadius: 32,
        offset: const Offset(0, 10),
        spreadRadius: -8,
      ),
    ],
  );
}

/// The app's theme for a given [brightness]. Both the light and dark themes are
/// built from this one function so the two never drift; the color tokens above
/// resolve against [AppTheme.brightness] at paint time.
ThemeData buildAppTheme({Brightness brightness = Brightness.light}) {
  final isDark = brightness == Brightness.dark;
  final scheme = isDark
      ? const ColorScheme.dark(
          primary: AppPalette.accent,
          onPrimary: Colors.white,
          secondary: AppPalette.accent,
          surface: Color(0xFF0A0A0A),
          onSurface: Color(0xFFF5F5F5),
          onSurfaceVariant: Color(0xFFA8A8A2),
          surfaceContainerHighest: Color(0xFF1E1E1E),
          outline: Color(0x14FFFFFF),
          outlineVariant: Color(0x14FFFFFF),
          error: Color(0xFFF2544B),
        )
      : const ColorScheme.light(
          primary: AppPalette.accent,
          onPrimary: Colors.white,
          secondary: AppPalette.accent,
          // Pure white — matches AppPalette.windowBg so the chat pane (which
          // paints scheme.surface) reads as clean white, letting the composer's
          // rim and shadow stand out instead of blending into an off-white wash.
          surface: Color(0xFFFFFFFF),
          onSurface: Color(0xFF1A1A18),
          onSurfaceVariant: Color(0xFF62615B),
          surfaceContainerHighest: Color(0xFFF3F3F2),
          outline: Color(0x0F000000),
          outlineVariant: Color(0x0F000000),
          error: Color(0xFFB3261E),
        );

  // The chrome fills used by menus/dialogs/snackbars. A getter-backed token can't
  // be a compile-time const, so these are resolved here per-brightness.
  final menuFill = isDark ? const Color(0xFF1E1E1E) : Colors.white;
  final textTheme = _appTextTheme(scheme.onSurface, scheme.onSurfaceVariant);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    dividerColor: scheme.outline,
    dividerTheme: DividerThemeData(
      color: scheme.outline,
      thickness: 1,
      space: 1,
    ),
    splashFactory: InkRipple.splashFactory,
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    iconTheme: IconThemeData(color: scheme.onSurfaceVariant, size: 18),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.all(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? AppPalette.accent
            : (isDark ? const Color(0xFF3A3A3A) : const Color(0xFFA3A29C)),
      ),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
      hintStyle: TextStyle(
        color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
      ),
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
      color: menuFill,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(menuFill),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(8),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: menuFill,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      width: 520,
      backgroundColor: menuFill,
      contentTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 13.5,
        fontWeight: FontWeight.w600,
      ),
      actionTextColor: AppPalette.accent,
      closeIconColor: scheme.onSurfaceVariant,
      elevation: 10,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
    ),
  );
}

TextTheme _appTextTheme(Color primary, Color secondary) {
  final base = TextStyle(
    fontFamily: '.AppleSystemUIFont',
    fontFamilyFallback: const ['SF Pro Text', 'Helvetica Neue', 'Arial'],
    color: primary,
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
    bodySmall: base.copyWith(fontSize: 13.5, color: secondary),
    labelLarge: base.copyWith(fontSize: 14.5, fontWeight: FontWeight.w600),
    labelMedium: base.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
    labelSmall: base.copyWith(fontSize: 12, fontWeight: FontWeight.w600),
  );
}
