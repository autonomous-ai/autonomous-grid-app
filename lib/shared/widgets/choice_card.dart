import 'package:flutter/material.dart';

import '../../features/provider_node/presentation/engine_block.dart';

/// One way to do a thing, said in as few words as it takes: an icon, a title,
/// one line, one button.
///
/// The shape is the point, and it's why this is shared: the first-run screen and
/// the Model Engines tab offer the *same* three ways onto a grid, and a user who
/// picked one on the way in should meet it wearing the same clothes later.
/// Detail (which models, whose bill, how big the download) belongs after the
/// choice — revealed in [footer] once the button is pressed — not in front of
/// it. A card that can't act right now passes its reason as [action] instead of
/// a button.
class ChoiceCard extends StatelessWidget {
  const ChoiceCard({
    super.key,
    required this.icon,
    required this.title,
    required this.line,
    required this.action,
    this.footer,
  });

  final IconData icon;
  final String title;

  /// The one line under the title. One, not a paragraph: this is the first
  /// screen of the app, and every extra clause is another thing to read before
  /// a decision the user can change later.
  final String line;

  /// The one thing this card does — a plain button, or the vendor's own
  /// sign-in control where the choice hands an account over to them.
  final Widget action;

  /// Anything that only exists after the card is acted on — a form the button
  /// revealed, or the reason it didn't work.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: EngineSurface(
        // Icon in its own gutter; everything the user reads or clicks lines up
        // in the column beside it. The button used to sit outside that column,
        // against the card's edge, so it hung left of the text above it.
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                icon,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    line,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Align(alignment: Alignment.centerLeft, child: action),
                  if (footer != null) ...[const SizedBox(height: 14), footer!],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
