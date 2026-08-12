import 'package:flutter/material.dart';

import '../../../shared/panels/panel_surface.dart';
import '../../../shared/panels/panel_tabs.dart';
import 'panel_feature_view.dart';

/// The work surface beside the conversation.
///
/// The panel itself — its tabs, its launcher, its "+" — is [PanelSurface],
/// shared with the panel beside a Code project so the two cannot drift apart.
/// What this adds is the only thing that differs: each tab is rooted at the
/// folder *this chat* works in.
class PreviewPanel extends StatelessWidget {
  const PreviewPanel({super.key, this.onRaisedSurface = false});

  /// Set when the panel is floating over the chat rather than docked beside it
  /// — see [PanelSurface.onRaisedSurface].
  final bool onRaisedSurface;

  @override
  Widget build(BuildContext context) => PanelSurface(
    host: PanelHost.preview,
    onRaisedSurface: onRaisedSurface,
    viewBuilder: (tab, {required onClose}) =>
        panelFeatureView(tab, host: PanelHost.preview, onClose: onClose),
  );
}
