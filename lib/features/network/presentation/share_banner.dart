import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_icon_button.dart';

/// What a [ShareBanner] is reporting, which decides its colour.
enum ShareBannerTone {
  /// Something is happening or has just happened — the grid is restarting.
  info,

  /// Something is about to be given up, and hasn't been yet.
  warning,
}

/// The strip across the top of the share sheet, under the title.
///
/// Google Docs puts its access requests here ("X asked to become an editor"),
/// and the slot is the right one to borrow even though Grid has no such
/// request: it is where the sheet says what is happening to *this document
/// right now*, above every control, before anyone reads a list.
///
/// Grid's version carries the two things Docs never has to say — that changing
/// the access rule takes something away, and that saving it restarts the grid
/// out from under everyone on it.
class ShareBanner extends StatelessWidget {
  const ShareBanner({
    super.key,
    required this.message,
    this.tone = ShareBannerTone.info,
    this.icon,
    this.onDismiss,
  });

  final String message;
  final ShareBannerTone tone;

  /// Optional glyph in a filled circle, the way Docs puts the requester's
  /// avatar at the head of its banner.
  final IconData? icon;

  /// Null while the banner reports something the reader cannot dismiss — a
  /// warning about a change they still have to decide on.
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final warning = tone == ShareBannerTone.warning;
    // Two washes of the same colour the text is drawn in, which is what keeps
    // the strip readable in both themes: the fill is the ink at low alpha over
    // the dialog, not a second colour chosen to sit beside it.
    final ink = warning ? AppPalette.warn : AppPalette.accentOnSurface;
    final fill = warning
        ? AppPalette.warn.withValues(alpha: AppTheme.pick(0.12, 0.16))
        : AppSurface.accentWash;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon case final glyph?) ...[
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(glyph, size: 16, color: ink),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: ink, fontSize: 12.5, height: 1.42),
            ),
          ),
          if (onDismiss case final dismiss?) ...[
            const SizedBox(width: 8),
            AppIconButton(
              icon: LucideIcons.x300,
              tooltip: 'Dismiss',
              color: ink,
              hoverColor: ink,
              onPressed: dismiss,
            ),
          ],
        ],
      ),
    );
  }
}
