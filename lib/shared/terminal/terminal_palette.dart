import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

import '../../../shared/theme/app_theme.dart';

/// The faces a terminal falls back to for glyphs no code font carries — behind
/// [AppFont.monoFallback], never in front of it.
///
/// A terminal outside this app reaches the whole system font book, and Flutter
/// reaches exactly the list it is given. **So this list is the book, in the
/// order the system itself would have read it**: each entry below is what
/// `CTFontCreateForString` picks for that character over a Menlo base — the
/// same call Terminal.app makes — rather than a face that looked likely.
///
/// Over a real code face only four characters fall through at all, and Claude
/// Code prints all four:
///
///     ⏺ U+23FA  every answer, every tool call   -> STIX Two Math
///     ⏵ U+23F5  the run marker                  -> STIX Two Math
///     ⎿ U+23BF  the branch under a tool result  -> Hiragino Sans
///     ⧉ U+29C9  copy/duplicate                  -> Apple Symbols
///
/// **The order is the whole fix.** `Apple Symbols` does not carry U+23FA, so
/// listing it first only got as far as the next entry — and the next entry was
/// an emoji face, which is where the app's own `⏺` came from: a blue rounded
/// square, drawn in the font's own colours rather than in the colour the CLI
/// asked for, beside a terminal drawing a plain dot. An emoji face answers a
/// question no code font was asked, so it belongs last: after it, nothing else
/// is ever reached.
///
/// The faces are not monospaced and a glyph taken from one can run wider than
/// its cell (`⎿` measures 12.5px in a 7.5px cell). That is what the terminal the
/// user is comparing against does too, and a character drawn a little wide
/// reads as the character; a tofu box reads as a broken app.
///
/// Names for the other two platforms are harmless where they don't exist — an
/// unmatched family is skipped.
const List<String> kTerminalSymbolFallback = [
  // macOS, in CoreText's own order.
  'STIX Two Math',
  'Hiragino Sans',
  'Apple Symbols',
  // Windows and Linux, for the same characters.
  'Segoe UI Symbol',
  'Noto Sans Symbols 2',
  'DejaVu Sans',
  // Last, and only for what is genuinely an emoji.
  'Apple Color Emoji',
  'Noto Color Emoji',
  'Segoe UI Emoji',
];

/// The colours a terminal draws with, in the app's current brightness.
///
/// Built here rather than taking `TerminalThemes.defaultTheme` because that one
/// is a fixed dark theme: its `#1E1E1E` background would sit as a grey slab in
/// the middle of a white window every time the user is in Light. The page
/// colours — background, foreground, cursor, selection — come from the app's own
/// tokens so the panel is part of the window.
///
/// The sixteen ANSI colours do **not**. They are VS Code's Dark+/Light+ ramps,
/// unchanged: a program that prints `\e[31m` is naming *red*, and the user has
/// spent years learning what their tools' output looks like. Re-tinting those to
/// the app's palette would make `git diff` and `flutter test` unreadable in a way
/// no amount of brand consistency pays for. What we owe them is a background
/// they stay legible on, which is what picking the ramp per brightness does.
TerminalTheme terminalPalette() => AppTheme.isDark ? _dark : _light;

TerminalTheme get _dark => TerminalTheme(
  cursor: AppPalette.accentOnSurface,
  selection: AppPalette.accentOnSurface.withValues(alpha: 0.35),
  foreground: AppPalette.textPrimary,
  background: AppPalette.windowBg,
  black: const Color(0xFF000000),
  red: const Color(0xFFCD3131),
  green: const Color(0xFF0DBC79),
  yellow: const Color(0xFFE5E510),
  blue: const Color(0xFF2472C8),
  magenta: const Color(0xFFBC3FBC),
  cyan: const Color(0xFF11A8CD),
  white: const Color(0xFFE5E5E5),
  brightBlack: const Color(0xFF666666),
  brightRed: const Color(0xFFF14C4C),
  brightGreen: const Color(0xFF23D18B),
  brightYellow: const Color(0xFFF5F543),
  brightBlue: const Color(0xFF3B8EEA),
  brightMagenta: const Color(0xFFD670D6),
  brightCyan: const Color(0xFF29B8DB),
  brightWhite: const Color(0xFFFFFFFF),
  searchHitBackground: const Color(0xFFFFFF2B),
  searchHitBackgroundCurrent: const Color(0xFF31FF26),
  searchHitForeground: const Color(0xFF000000),
);

TerminalTheme get _light => TerminalTheme(
  cursor: AppPalette.accentOnSurface,
  selection: AppPalette.accentOnSurface.withValues(alpha: 0.25),
  foreground: AppPalette.textPrimary,
  background: AppPalette.windowBg,
  black: const Color(0xFF000000),
  red: const Color(0xFFCD3131),
  green: const Color(0xFF00BC00),
  yellow: const Color(0xFF949800),
  blue: const Color(0xFF0451A5),
  magenta: const Color(0xFFBC05BC),
  cyan: const Color(0xFF0598BC),
  white: const Color(0xFF555555),
  brightBlack: const Color(0xFF666666),
  brightRed: const Color(0xFFCD3131),
  brightGreen: const Color(0xFF14CE14),
  brightYellow: const Color(0xFFB5BA00),
  brightBlue: const Color(0xFF0451A5),
  brightMagenta: const Color(0xFFBC05BC),
  brightCyan: const Color(0xFF0598BC),
  brightWhite: const Color(0xFFA5A5A5),
  searchHitBackground: const Color(0xFFFFFF2B),
  searchHitBackgroundCurrent: const Color(0xFF31FF26),
  searchHitForeground: const Color(0xFF000000),
);
