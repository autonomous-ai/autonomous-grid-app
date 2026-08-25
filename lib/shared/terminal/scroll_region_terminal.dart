import 'dart:math' show min;

import 'package:xterm/core.dart';

/// The emulator every terminal in this app draws from: `xterm`, with the one
/// thing it gets wrong about **scroll regions** taken off it.
///
/// An agent's CLI does not print its transcript — it *scrolls* it. Codex sets a
/// region around the block it keeps pinned at the bottom, pushes that block
/// down, sets a second region above it and line-feeds the finished lines into
/// the scrollback:
///
///     ESC[24;30r  ESC[24;1H  ESC M ESC M   the pinned block moves down
///     ESC[r  ESC[1;25r  ESC[23;1H          the region above it
///     \r\n <line> \r\n <line>  ESC[r       the lines, on their way up
///
/// **Stock `xterm 4.0.0` shreds exactly that.** `Buffer.scrollUp`,
/// `Buffer.scrollDown` and `Buffer.deleteLines` move lines between slots by
/// reference (`lines[i] = lines[j]`), which leaves one `BufferLine` in two slots
/// for an instant — and the write that fills the slot it came from detaches it
/// while the buffer is still holding it. Everything that touches that line
/// afterwards throws `Null check operator used on a null value`, out of
/// `Terminal.write`, which is the pty's own output listener: one throw per byte
/// from then on, which is why the screen stops at the last line that landed.
/// `Buffer.insertLines` is the same move written safely (`lines.swap`) and is
/// left alone.
///
/// Measured by replaying a real Codex session (v0.144.6, 100×14) through both:
/// stock threw on **32 writes** and finished with **0 lines of scrollback** —
/// nothing above the fold to scroll to, and rows written into the middle of
/// other rows. Through this class: **0 throws, 32 lines of scrollback**, equal
/// line for line to an independent emulator (`pyte`) bar two.
///
/// The fix is to move the *contents* of the lines rather than the line objects,
/// so no line is ever in two slots and none is detached while in use. The one
/// path still left to [Buffer] is the one it is right about, and the only one
/// that feeds the scrollback: a line feed at the bottom of a region that starts
/// at the top of the screen inserts a line below the region rather than moving
/// any, so the line leaving the screen lands above the fold (`Buffer.index`).
///
/// TODO(BE): this is a patch over a dependency, held to it by nothing but this
/// file. `xterm 4.0.0` is the latest published version and the bug is in its
/// core, so an upgrade cannot be assumed to fix it — re-run
/// `test/agent/terminal_scroll_region_test.dart` after one, and read
/// `Buffer.scrollUp` before deleting anything here.
class ScrollRegionTerminal extends Terminal {
  ScrollRegionTerminal({super.maxLines});

  @override
  void index() {
    if (_movesRegionByReference(buffer)) {
      _scrollRegion(up: true, count: 1);
      return;
    }
    buffer.index();
  }

  @override
  void lineFeed() {
    index();
    if (lineFeedMode) buffer.setCursorX(0);
  }

  @override
  void nextLine() {
    index();
    buffer.setCursorX(0);
  }

  @override
  void reverseIndex() {
    final b = buffer;
    if (b.isInVerticalMargin && b.cursorY == b.marginTop) {
      _scrollRegion(up: false, count: 1);
      return;
    }
    b.reverseIndex();
  }

  @override
  void scrollUp(int amount) => _scrollRegion(up: true, count: amount);

  @override
  void scrollDown(int amount) => _scrollRegion(up: false, count: amount);

  @override
  void deleteLines(int amount) {
    final b = buffer;
    if (!b.isInVerticalMargin) return;
    // Lines below the cursor move up over it; the region's own bottom is where
    // the blanks land — the cursor's row is the top of the move, not the
    // region's.
    b.setCursorX(0);
    _move(
      top: b.absoluteCursorY,
      bottom: b.absoluteMarginBottom,
      up: true,
      count: amount,
    );
  }

  /// Whether a line feed here would send [Buffer.index] down one of the paths
  /// that move lines by reference. Mirrors its branches, so that what this
  /// class takes over and what it leaves alone stay the same set.
  bool _movesRegionByReference(Buffer b) {
    if (b.isInVerticalMargin) {
      return b.cursorY == b.marginBottom && (b.marginTop != 0 || b.isAltBuffer);
    }
    // Below the region, on the last row of an alternate screen — which has no
    // scrollback to feed, so there is nothing to insert and upstream scrolls.
    return b.cursorY >= b.viewHeight - 1 && b.isAltBuffer;
  }

  void _scrollRegion({required bool up, required int count}) => _move(
    top: buffer.absoluteMarginTop,
    bottom: buffer.absoluteMarginBottom,
    up: up,
    count: count,
  );

  /// Moves the contents of lines [top]..[bottom] by [count] rows, blanking the
  /// [count] rows left behind at the far end.
  ///
  /// Contents, not lines: every `BufferLine` stays in the slot it is in, so
  /// none of them is ever aliased into two slots and none is detached out from
  /// under the buffer.
  void _move({
    required int top,
    required int bottom,
    required bool up,
    required int count,
  }) {
    final width = buffer.viewWidth;
    final lines = buffer.lines;
    final rows = min(count, bottom - top + 1);
    if (rows <= 0) return;
    if (up) {
      for (var i = top; i <= bottom - rows; i++) {
        _copy(lines[i + rows], lines[i], width);
      }
      for (var i = bottom - rows + 1; i <= bottom; i++) {
        _blank(lines[i], width);
      }
      return;
    }
    for (var i = bottom; i >= top + rows; i--) {
      _copy(lines[i - rows], lines[i], width);
    }
    for (var i = top; i < top + rows; i++) {
      _blank(lines[i], width);
    }
  }

  /// [from] over [to], padded with blanks when the source is the shorter of the
  /// two — a line only holds as many cells as it was last resized to, and
  /// reading past that reads whatever the buffer behind it still held.
  static void _copy(BufferLine from, BufferLine to, int width) {
    final cells = min(width, from.length);
    to.copyFrom(from, 0, 0, cells);
    if (cells < width) to.eraseRange(cells, width, CursorStyle.empty);
  }

  static void _blank(BufferLine line, int width) {
    line.resize(width);
    line.eraseRange(0, width, CursorStyle.empty);
  }
}
