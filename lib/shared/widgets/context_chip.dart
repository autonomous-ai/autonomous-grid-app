import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/app_theme.dart';
import 'chip_remove_button.dart';

/// A chip naming something riding on a message that isn't a file — today, a
/// terminal the user has open.
///
/// One widget for both places it appears — waiting in the composer, where it can
/// still be taken off, and sent in the transcript, where it says what went with
/// the message — so the two can't drift into looking like different things.
/// [FileChip] is the same idea for documents, and these sit in a row together.
///
/// Nothing to tap: a file chip opens its file, but a terminal is already on
/// screen a few inches away.
class ContextChip extends StatelessWidget {
  const ContextChip({
    super.key,
    required this.label,
    required this.tooltip,
    this.onRemove,
  });

  final String label;

  /// What the chip has no room for: where the terminal is, and what will
  /// actually be sent.
  final String tooltip;

  /// Takes it off this message. Null in the transcript: a message that has been
  /// sent can't un-attach anything.
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppPalette tokens — follow theme flips
    final radius = BorderRadius.circular(8);
    // Narrower than a file chip, because it carries less: a file says its name
    // and its size, a terminal says one word. At the file chip's width two of
    // these fill half the composer to hold "Terminal" twice.
    //
    // The same height as one, though. Tightening it vertically as well bought
    // nothing — the row is as tall as the tallest thing in it either way — and
    // cost 8px of difference that shows the moment a terminal chip stands next
    // to a file chip, which is now the ordinary case rather than a separate row.
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: EdgeInsets.fromLTRB(8, 7, onRemove == null ? 8 : 2, 7),
        decoration: BoxDecoration(
          color: AppPalette.cardBg,
          borderRadius: radius,
          border: Border.all(color: AppPalette.divider),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Every context is a terminal today; when a second kind arrives it
            // will need a field on the model saying which, because a chip read
            // back out of a saved conversation has nothing else to go on.
            Icon(
              LucideIcons.squareTerminal,
              size: 13,
              color: AppPalette.textSecondary,
            ),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: AppFont.medium,
                ),
              ),
            ),
            if (onRemove != null)
              ChipRemoveButton(
                onTap: onRemove!,
                semanticLabel: 'Remove terminal',
                size: 12,
              ),
          ],
        ),
      ),
    );
  }
}
