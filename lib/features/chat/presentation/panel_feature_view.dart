import 'package:flutter/material.dart';

import '../../browser/presentation/browser_panel_view.dart';
import '../../files/presentation/files_panel_view.dart';
import '../../review/presentation/review_panel_view.dart';
import '../../side_chat/presentation/side_chat_panel_view.dart';
import '../../terminal/presentation/terminal_panel_view.dart';
import '../logic/panel_tabs.dart';

/// The one place a [PanelFeature] becomes a widget.
///
/// Reaching across into five other features' `presentation/` is the thing the
/// layering rule forbids everywhere else, and this is the same exemption
/// `shared/layouts/widgets/section_view.dart` takes for the shell: a mapping
/// table has to name both sides. Keeping it to one file is what stops the
/// exemption spreading — nothing else in `chat/` knows these classes exist.
Widget panelFeatureView(PanelFeature feature) => switch (feature) {
  PanelFeature.review => const ReviewPanelView(),
  PanelFeature.terminal => const TerminalPanelView(),
  PanelFeature.browser => const BrowserPanelView(),
  PanelFeature.files => const FilesPanelView(),
  PanelFeature.sideChat => const SideChatPanelView(),
};
