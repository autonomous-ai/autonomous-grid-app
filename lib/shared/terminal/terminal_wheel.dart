import 'package:xterm/core.dart';

/// The mouse, reported to the program the way the program expects — which for
/// the **wheel** is not what `xterm 4.0.0` sends.
///
/// A wheel notch is button 4 (up) or 5 (down), and buttons 4–7 are reported
/// with bit 6 set instead of their low bits: `64` and `65`. `xterm 4.0.0` adds
/// the 64 to the button number rather than replacing it
/// (`TerminalMouseButton.wheelUp(id: 64 + 4)`), so every notch goes out as
/// **68**, which is a wheel event carrying the *shift* modifier — a different
/// event, and one that TUIs are right to ignore.
///
/// Measured against Claude Code 2.1.241, which lives on the alternate screen
/// (no scrollback of its own to fall back on) with mouse tracking on, so the
/// wheel is the only way to see what it said earlier. Five notches of
/// `ESC[<68;…M` — what the app sent — changed nothing at all; five of
/// `ESC[<64;…M` scrolled its transcript to the top and drew its own "Jump to
/// bottom" control. The reported *cell* it ignores entirely: a notch reported
/// at column 150 row 30 of a 100×14 screen scrolls just as well, which is worth
/// knowing because `xterm` computes that cell from the pointer's **global**
/// position and so names a cell tens of columns off in a window with a sidebar.
///
/// Everything that is not the wheel falls through to `defaultMouseHandler`
/// unchanged.
const terminalMouseHandler = CascadeMouseHandler([
  _WheelHandler(),
  defaultMouseHandler,
]);

class _WheelHandler implements TerminalMouseHandler {
  const _WheelHandler();

  @override
  String? call(TerminalMouseEvent event) {
    if (!event.button.isWheel) return null;
    // The modes that don't report scrolling at all — the caller falls back to
    // arrow keys, which is what a terminal does for a program that never asked
    // for the mouse.
    if (!event.state.mouseMode.reportScroll) return null;
    // A wheel has no release to report: the notch is the whole event.
    if (event.buttonState == TerminalMouseButtonState.up) return null;
    final id = _wheelId(event.button);
    if (id == null) return null;

    // Both are 1-based on the wire.
    final x = event.position.x + 1;
    final y = event.position.y + 1;
    return switch (event.state.mouseReportMode) {
      MouseReportMode.sgr => '\x1b[<$id;$x;${y}M',
      MouseReportMode.urxvt => '\x1b[${32 + id};$x;${y}M',
      // The oldest encoding: each number is a printable character, so anything
      // past 223 has no room to be said and is sent as a null byte instead.
      MouseReportMode.normal || MouseReportMode.utf =>
        '\x1b[M${_char(32 + id)}${_coordinate(x, event.state.mouseReportMode)}'
            '${_coordinate(y, event.state.mouseReportMode)}',
    };
  }

  int? _wheelId(TerminalMouseButton button) => switch (button) {
    TerminalMouseButton.wheelUp => 64,
    TerminalMouseButton.wheelDown => 65,
    TerminalMouseButton.wheelLeft => 66,
    TerminalMouseButton.wheelRight => 67,
    _ => null,
  };

  String _coordinate(int value, MouseReportMode mode) {
    final limit = mode == MouseReportMode.utf ? 2015 : 223;
    return value > limit ? '\x00' : _char(32 + value);
  }

  String _char(int code) => String.fromCharCode(code);
}
