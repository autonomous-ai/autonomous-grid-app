import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the bottom panel — the strip under the conversation, where a
/// terminal will run — is open.
///
/// Its own flag rather than a mode of the preview panel: the two occupy
/// different edges and are read at the same time, so opening one must never
/// close the other. Not persisted, for the same reason the preview panel isn't
/// — see `previewPanelOpenProvider`.
final bottomPanelOpenProvider = NotifierProvider<BottomPanelOpen, bool>(
  BottomPanelOpen.new,
);

class BottomPanelOpen extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;

  void close() => state = false;
}
