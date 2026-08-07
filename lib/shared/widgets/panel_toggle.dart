import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_icon_button.dart';

/// One of the buttons that opens a panel around the conversation — the project
/// rail, the bottom panel, the preview panel.
///
/// Shared because the same control appears in two places: the top bar carries
/// all three, and the preview panel's own header carries the last two. They have
/// to be the same button rather than lookalikes that drift apart.
///
/// Lit with [AppPalette.accentOnSurface] rather than `accent` when open:
/// `accent` is a fill colour and measures 2.6:1 used as ink on a dark pane.
class PanelToggle extends StatelessWidget {
  const PanelToggle({
    super.key,
    required this.icon,
    required this.open,
    required this.label,
    required this.onPressed,
    this.leading = 4,
  });

  final IconData icon;

  /// Whether the panel this opens is showing — lights the glyph, and picks
  /// between the "Show …" and "Hide …" tooltip.
  final bool open;

  /// What the button moves, lower-case, for that tooltip. The word on the
  /// button has to be the word a user would use for the thing that appears.
  final String label;

  final VoidCallback onPressed;

  /// The gap before the button. The first toggle in a group stands off whatever
  /// it follows; the rest sit close enough to read as one cluster.
  final double leading;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: EdgeInsets.only(left: leading),
      child: AppIconButton(
        icon: icon,
        size: 16,
        tooltip: open ? 'Hide $label' : 'Show $label',
        color: open ? AppPalette.accentOnSurface : AppPalette.textSecondary,
        hoverColor: open ? AppPalette.accentOnSurface : AppPalette.textPrimary,
        onPressed: onPressed,
      ),
    );
  }
}
