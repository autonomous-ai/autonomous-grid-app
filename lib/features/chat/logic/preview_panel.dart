import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the preview panel — the work surface beside the conversation — is
/// open.
///
/// Deliberately not persisted, and deliberately not per-chat: the panel is a
/// place to *do* something next to whatever you are saying, so it stays open
/// while you move between chats and starts closed in a window you have just
/// opened. The project rail's override sticks because it answers "do I want to
/// see this project's cards"; this one answers "am I working in here right
/// now".
final previewPanelOpenProvider = NotifierProvider<PreviewPanelOpen, bool>(
  PreviewPanelOpen.new,
);

class PreviewPanelOpen extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;

  void close() => state = false;

  void open() => state = true;
}

/// Whether the preview panel has the whole pane, with the conversation slid out
/// from under it.
///
/// A second state of the same panel rather than a second panel: what you are
/// doing in there — reading a long diff, watching a build scroll past — is
/// sometimes the whole job for a minute, and 45% of the window is not enough of
/// it. The chat is hidden rather than closed, so the draft, the scroll and the
/// turn in flight are all still there when it comes back.
final previewPanelExpandedProvider =
    NotifierProvider<PreviewPanelExpanded, bool>(PreviewPanelExpanded.new);

class PreviewPanelExpanded extends Notifier<bool> {
  @override
  bool build() {
    // Expanded is a state an *open* panel can be in, so opening or closing the
    // panel puts it back to its normal width. Without this, closing while
    // expanded would leave the flag set and the next open would swallow the
    // conversation with no warning.
    ref.watch(previewPanelOpenProvider);
    return false;
  }

  void toggle() => state = !state;
}
