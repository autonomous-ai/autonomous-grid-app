import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';

/// The tick under the model picker: share this model the moment Grid opens.
///
/// Unticked out of the box, and it says what that means either way — serving
/// runs the user's own graphics card, so "nothing happens until you press
/// Start" is the promise the rest of the app makes, and this is the one place
/// they can change it.
class AutoServeRow extends StatelessWidget {
  const AutoServeRow({
    super.key,
    required this.value,
    required this.modelLabel,
    required this.armedElsewhere,
    required this.onChanged,
  });

  final bool value;

  /// Another model already set to start on open, if there is one. An unticked
  /// box next to this model must not read as "nothing starts by itself" while
  /// something else does.
  final String? armedElsewhere;

  /// The model that would start — named out loud, because the tick follows the
  /// picker above and the user should be able to read back what they chose.
  final String modelLabel;

  final ValueChanged<bool> onChanged;

  /// What ticking it does, or what is happening instead.
  String get _subtitle {
    if (value) {
      return '“$modelLabel” starts sharing on this grid as soon as you open '
          'the app.';
    }
    return switch (armedElsewhere) {
      final other? => '“$other” is the one set to start when Grid opens.',
      _ => 'Off — this computer only shares a model when you press Start.',
    };
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(AppCard.insetRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: Checkbox(
                value: value,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (next) => onChanged(next ?? false),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Start this model when Grid opens',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppPalette.textFaint,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
