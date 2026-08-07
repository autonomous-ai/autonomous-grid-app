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
