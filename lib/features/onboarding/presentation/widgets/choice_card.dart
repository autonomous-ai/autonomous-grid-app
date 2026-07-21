import 'package:flutter/material.dart';

import '../../../../shared/widgets/app_spinner.dart';
import '../../../provider_node/presentation/engine_block.dart';

/// One way to get started, said in as few words as it takes: an icon, a title,
/// two short lines, one button.
///
/// The shape is the point. This is the first screen of the app, before the user
/// has decided anything — a paragraph of caveats per option is a settings form
/// wearing a welcome screen's clothes. Detail (which models, whose bill, how big
/// the download) belongs after the choice, not in front of it.
class ChoiceCard extends StatelessWidget {
  const ChoiceCard({
    super.key,
    required this.icon,
    required this.title,
    required this.line,
    required this.actionLabel,
    required this.onPressed,
    this.busy = false,
    this.busyLabel,
    this.footer,
  });

  final IconData icon;
  final String title;

  /// The one line under the title. One, not a paragraph: this is the first
  /// screen of the app, and every extra clause is another thing to read before
  /// a decision the user can change later.
  final String line;

  final String actionLabel;
  final VoidCallback onPressed;

  /// The choice is under way: the button holds a spinner and [busyLabel], so a
  /// second tap can't start it twice.
  final bool busy;
  final String? busyLabel;

  /// Anything that only exists after the card is acted on — a form the button
  /// revealed, or the reason it didn't work.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: EngineSurface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
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
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: busy ? null : onPressed,
                icon: busy ? const AppSpinner() : const SizedBox.shrink(),
                label: Text(busy ? (busyLabel ?? actionLabel) : actionLabel),
              ),
            ),
            if (footer != null) ...[const SizedBox(height: 14), footer!],
          ],
        ),
      ),
    );
  }
}
