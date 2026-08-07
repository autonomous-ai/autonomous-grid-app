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

/// What the preview panel is showing.
///
/// The panel is a host, not a screen: it holds one work surface at a time, and
/// [PreviewSurface.launcher] — the list of what it can open — is a surface like
/// any other rather than a special empty state.
enum PreviewSurface {
  /// What the panel can open. Where it starts, and where closing a surface
  /// returns to.
  launcher,

  /// What has changed in the project's folder.
  review,
}

/// Which surface the panel holds. Not per chat, for the reason the open/closed
/// flag isn't: it answers "what am I working on right now", and moving between
/// conversations doesn't change that.
final previewSurfaceProvider =
    NotifierProvider<PreviewSurfaceController, PreviewSurface>(
      PreviewSurfaceController.new,
    );

class PreviewSurfaceController extends Notifier<PreviewSurface> {
  @override
  PreviewSurface build() => PreviewSurface.launcher;

  /// Show [surface], opening the panel if it was closed — every way in is
  /// somebody asking to *see* something.
  void open(PreviewSurface surface) {
    state = surface;
    ref.read(previewPanelOpenProvider.notifier).open();
  }

  /// Back to the list of what the panel can open.
  void showLauncher() => state = PreviewSurface.launcher;
}
