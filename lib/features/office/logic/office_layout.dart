import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/logic/panel_layout.dart';

/// How wide the chat beside the document is, in logical pixels.
///
/// A provider rather than state inside the screen, for a reason the app's own
/// navigation creates: `SectionView` keys its child by section, so leaving Docs
/// and coming back builds a fresh widget — a width kept in the widget would snap
/// to the default every time the user glanced at another screen.
///
/// Session state. Deliberately not persisted yet: it is one number, and the app
/// has nowhere it keeps window furniture between launches.
final officeChatWidthProvider =
    NotifierProvider<OfficeChatWidthNotifier, double>(
      OfficeChatWidthNotifier.new,
    );

class OfficeChatWidthNotifier extends Notifier<double> {
  /// The narrowest the column may be — and it is [kChatMinWidth], the floor the
  /// chat pane already measured for the very same composer.
  ///
  /// Not a number chosen for this screen. Docs embeds `ChatView` whole, so it
  /// inherits that composer's floor exactly: the row of controls under the text
  /// field stops tightening around 396px and stripes below it. This started at a
  /// borrowed 360 — genoffice's AI panel width — and 360 is under the floor, so
  /// the composer overflowed at the width the screen *opened* at.
  static const minimum = kChatMinWidth;

  /// Where the column opens: at its floor, which gives the page every pixel the
  /// chat doesn't need.
  static const initial = kChatMinWidth;

  /// Past this the chat stops being the column beside the document and starts
  /// being the screen — at which point the user wants the Chat section.
  static const maximum = 620.0;

  @override
  double build() => initial;

  /// Move the seam by [delta] logical pixels, positive to the right.
  void nudge(double delta) => state = (state + delta).clamp(minimum, maximum);

  void reset() => state = initial;
}
