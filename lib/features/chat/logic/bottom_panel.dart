import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the bottom panel — the strip under the conversation, where the
/// terminal runs — is open.
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

  /// Shows the panel without closing it when it is already up — what opening a
  /// tab in it means, as opposed to pressing its button.
  void open() => state = true;

  void close() => state = false;
}
