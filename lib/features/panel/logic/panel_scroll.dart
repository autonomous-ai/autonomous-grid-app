import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/panel/panel_message.dart';

/// How far the window's list moves per pixel the finger travels on the glass.
///
/// The panel is 466px tall and a transcript is thousands: one-to-one turns a
/// full sweep of the glass into a third of a screenful, which reads as a
/// touchpad with the batteries going. Measured on the hardware — see the note in
/// `docs/panel-protocol.md`; it is a feel, so it is a constant with a name
/// rather than a literal at the call site.
///
/// Applied to the release speed as well as the travel, so a flick throws the
/// list as far as the same flick would have dragged it.
const double kPanelScrollGain = 2.5;

/// One report of a finger moving on the panel, for whatever the window has open.
///
/// [seq] is what makes it deliverable. Two strokes of the same length are the
/// same value, and a provider that only publishes changes would swallow the
/// second — so the sequence number, not the distance, is what says "this is a
/// new one".
typedef PanelScrollTick = ({
  int seq,
  double dy,
  PanelScrollPhase phase,
  double velocity,
});

/// The panel's scrolling, published for the view that owns a scroll position.
///
/// **This exists because the dependency only runs one way** (conventions §1):
/// the panel controller is logic and a `ScrollController` belongs to a widget,
/// so the controller cannot reach in and move the list. It says how far the
/// finger went; the view that has a list decides what that means for it, and a
/// view with nothing to scroll ignores it without anybody arranging that.
final panelScrollProvider =
    NotifierProvider<PanelScroll, PanelScrollTick>(PanelScroll.new);

class PanelScroll extends Notifier<PanelScrollTick> {
  @override
  PanelScrollTick build() =>
      (seq: 0, dy: 0, phase: PanelScrollPhase.up, velocity: 0);

  /// The panel reported a stroke — a touch down, some travel, or a lift.
  ///
  /// Every report is published, including the ones carrying no travel: the ends
  /// of a stroke are the whole point of this. A `down` with nothing in it stops
  /// a fling still running, and an `up` with nothing in it is a finger that
  /// stopped before it left the glass, which must not be thrown.
  void reported(PanelScrolled scroll) {
    state = (
      seq: state.seq + 1,
      dy: scroll.dy,
      phase: scroll.phase,
      velocity: scroll.velocity,
    );
  }
}
