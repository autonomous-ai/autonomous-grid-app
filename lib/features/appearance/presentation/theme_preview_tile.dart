import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';

/// The colours one theme choice paints with — read from the app's own tokens at
/// that brightness, never re-typed here.
///
/// A preview that hardcodes its own greys is a picture of a theme rather than the
/// theme: it keeps looking right after the palette moves, which is exactly when a
/// preview needs to stop looking right. See [AppTheme.as].
class _Swatch {
  const _Swatch({
    required this.window,
    required this.panel,
    required this.card,
    required this.line,
    required this.accent,
  });

  factory _Swatch.of(Brightness brightness) => AppTheme.as(
    brightness,
    () => _Swatch(
      window: AppPalette.windowBg,
      panel: AppPalette.panelBg,
      card: AppCard.base,
      line: AppTheme.pick(const Color(0x22000000), const Color(0x33FFFFFF)),
      accent: AppPalette.accent,
    ),
  );

  final Color window;
  final Color panel;
  final Color card;
  final Color line;
  final Color accent;
}

/// One theme choice, previewed as a tiny picture of the app wearing it: the
/// sidebar rail on the left, a card of "text" on the right.
///
/// This is the macOS System Settings pattern — you pick an appearance by seeing
/// it, not by reading the word for it. System shows both halves at once, split
/// down the middle, because that is literally what it does.
class ThemePreviewTile extends StatelessWidget {
  const ThemePreviewTile({
    super.key,
    required this.mode,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final ThemeMode mode;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  static const double _width = 156;
  static const double _height = 96;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette below for its own chrome (the label, the selection ring),
    // so it has to follow the live theme like any other const-constructed widget.
    AppTheme.watch(context);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      // The whole tile is the target — picture *and* label. The label is the
      // part that reads as the thing's name, so it's the part a lot of people
      // aim at; a hit box that stopped at the artwork would swallow those
      // clicks silently.
      child: GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: _width,
                height: _height,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppCard.radius),
                  // The selection ring sits *outside* the artwork rather than
                  // over it — a border drawn on top would tint the very colours
                  // the tile exists to show.
                  border: Border.all(
                    color: selected ? AppPalette.accent : AppPalette.divider,
                    width: selected ? 2 : 1,
                  ),
                ),
                padding: const EdgeInsets.all(2),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppCard.radius - 3),
                  child: _artwork(),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                style: TextStyle(
                  fontFamily: AppFont.sans,
                  fontFamilyFallback: AppFont.sansFallback,
                  fontSize: 12,
                  // The picked one says so twice: the ring, and the ink.
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected
                      ? AppPalette.textPrimary
                      : AppPalette.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _artwork() => switch (mode) {
    ThemeMode.light => _MiniApp(swatch: _Swatch.of(Brightness.light)),
    ThemeMode.dark => _MiniApp(swatch: _Swatch.of(Brightness.dark)),
    // Both, split down the middle — the choice *is* "whichever the Mac is".
    ThemeMode.system => Row(
      children: [
        Expanded(
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              maxWidth: _width,
              child: SizedBox(
                width: _width,
                child: _MiniApp(swatch: _Swatch.of(Brightness.light)),
              ),
            ),
          ),
        ),
        Expanded(
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.centerRight,
              maxWidth: _width,
              child: SizedBox(
                width: _width,
                child: _MiniApp(swatch: _Swatch.of(Brightness.dark)),
              ),
            ),
          ),
        ),
      ],
    ),
  };
}

/// The picture inside a tile: the app in miniature — rail, then a card of ruled
/// "text" lines. Not a literal screenshot; just enough shape that the eye reads
/// "that's the app" and judges the colours.
class _MiniApp extends StatelessWidget {
  const _MiniApp({required this.swatch});

  final _Swatch swatch;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: swatch.window,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The rail, with the accent marking the row you're on — the one spot of
          // colour, exactly as in the app.
          SizedBox(
            width: 34,
            child: ColoredBox(
              color: swatch.panel,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(5, 9, 5, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Line(color: swatch.accent, width: 20, height: 4),
                    const SizedBox(height: 5),
                    _Line(color: swatch.line, width: 16, height: 3),
                    const SizedBox(height: 5),
                    _Line(color: swatch.line, width: 19, height: 3),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(7, 9, 7, 9),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: swatch.card,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Line(color: swatch.line, width: 44, height: 3),
                      const SizedBox(height: 4),
                      _Line(color: swatch.line, width: 62, height: 3),
                      const SizedBox(height: 4),
                      _Line(color: swatch.line, width: 52, height: 3),
                      const SizedBox(height: 4),
                      _Line(color: swatch.line, width: 36, height: 3),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A stroke standing in for a line of text or a nav row.
class _Line extends StatelessWidget {
  const _Line({required this.color, required this.width, required this.height});

  final Color color;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(height / 2),
    ),
  );
}
