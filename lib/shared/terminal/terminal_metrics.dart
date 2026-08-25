import 'dart:math' show min;

import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

import '../theme/app_theme.dart';
import 'terminal_palette.dart';

/// How a terminal is set: the size of its text, and how wide it is allowed to
/// grow before it stops.
///
/// **The width is the interesting one, and it is not a taste.** A CLI that draws
/// a TUI lays itself out in *columns*: Claude Code sizes its welcome box, its
/// message rows and every wrapped paragraph to whatever `$COLUMNS` says. A
/// terminal window on this machine runs 109×43; the chat pane at 12.5pt gives
/// the same program **154** columns, and the program obeys — the box stretches
/// edge to edge, its two panes drift apart, "What's new" truncates with `…`
/// because the box grew but the text inside it didn't, and a paragraph wraps at
/// 154 characters, half again the line length anything is meant to be read at.
///
/// So a chat that *is* a CLI stops the screen at [maxColumns] and centres it.
/// The strip either side stays the terminal's own background ([terminalPalette]
/// paints it), so it reads as a generous margin rather than as a slab with a
/// terminal sitting on it.
@immutable
class TerminalMetrics {
  const TerminalMetrics({
    required this.fontSize,
    required this.lineHeight,
    required this.padding,
    this.maxColumns,
    this.simulateScroll = true,
  });

  /// A Terminal tab: the app's code size, in a pane the user already sized
  /// themselves by dragging the panel.
  ///
  /// No [maxColumns] — a shell is not a TUI. `ls` and a build log are lines of
  /// their own length, and the wider the tab the fewer of them wrap.
  static const panel = TerminalMetrics(
    fontSize: 12.5,
    lineHeight: 1.2,
    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  );

  /// A chat that is an agent's own CLI.
  ///
  /// Measured off a real `claude` window rather than picked: 109 columns at
  /// 8.0px a cell, rows 17.4px apart — 13.3pt on a 1.31 line. Rounded to the
  /// numbers below, which land within a pixel of it.
  static const agent = TerminalMetrics(
    fontSize: 13,
    lineHeight: 1.3,
    padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    maxColumns: 110,
    simulateScroll: false,
  );

  final double fontSize;

  /// Line box as a multiple of [fontSize]. `xterm`'s own default is 1.2, which
  /// is tighter than any terminal app sets the same face.
  final double lineHeight;

  final EdgeInsets padding;

  /// The widest the screen may get, in columns, or null to fill the space.
  final int? maxColumns;

  /// Whether a wheel turn a program didn't ask for should be sent as an arrow
  /// key instead — `xterm`'s own fallback, and what a terminal does for a
  /// full-screen program with no scrollback of its own.
  ///
  /// **Off for an agent's CLI, because there the arrow keys mean something
  /// else.** Codex spends part of its life on the alternate screen without
  /// mouse tracking, and `Up` there walks the prompt history: measured on a live
  /// session, three `ESC[A` changed what was on screen. So a scroll gesture was
  /// not merely doing nothing — it was typing into the draft. Nothing is the
  /// better answer.
  final bool simulateScroll;

  /// The text style this hands `xterm`, on the app's own code face.
  ///
  /// **Cached, and it has to be.** `TerminalStyle` doesn't implement `==`, and
  /// `TerminalPainter.textStyle=` compares by that: a fresh instance per build
  /// therefore never matches, so every rebuild re-measured the cell and threw
  /// away a paragraph cache holding up to 10,240 laid-out cells. Keyed by the
  /// family too, because [AppFont.mono] resolves whatever the user chose in
  /// Appearance and that can change while the app is running.
  TerminalStyle get style => _cache
      .putIfAbsent(_key, () => (style: _buildStyle(), cell: null, line: null))
      .style;

  /// How wide the screen may be drawn inside [available], padding included.
  ///
  /// The cell is measured the way `xterm` measures it — ten `m`s laid out and
  /// divided — because the number has to agree with the one it will divide the
  /// box by. A pixel of slack, so a width that lands exactly on the boundary
  /// rounds to [maxColumns] rather than one short of it.
  double screenWidth(double available) {
    final columns = maxColumns;
    if (columns == null) return available;
    return min(available, columns * _cellWidth() + padding.horizontal + 1);
  }

  String get _key => '$fontSize/$lineHeight/${AppFont.mono}';

  TerminalStyle _buildStyle() => TerminalStyle(
    fontSize: fontSize,
    height: lineHeight,
    fontFamily: AppFont.mono,
    fontFamilyFallback: [...AppFont.monoFallback, ...kTerminalSymbolFallback],
  );

  /// The height of one row, the way `xterm` lays it out — what a wheel notch
  /// has to be divided by to become a number of lines.
  double lineBox() {
    _cellWidth();
    return _cache[_key]!.line!;
  }

  double _cellWidth() {
    final entry = _cache.putIfAbsent(
      _key,
      () => (style: _buildStyle(), cell: null, line: null),
    );
    if (entry.cell case final cached?) return cached;
    const probe = 'mmmmmmmmmm';
    final painter = TextPainter(
      text: TextSpan(text: probe, style: entry.style.toTextStyle()),
      textDirection: TextDirection.ltr,
    )..layout();
    final width = painter.maxIntrinsicWidth / probe.length;
    final line = painter.height;
    painter.dispose();
    _cache[_key] = (style: entry.style, cell: width, line: line);
    return width;
  }

  /// One entry per (size, line, family) in play — at most a handful, and they
  /// stay valid for as long as that family is the one the app is drawn in.
  static final Map<String, ({TerminalStyle style, double? cell, double? line})>
  _cache = {};
}
