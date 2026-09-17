/// The controls a settings row is built from.
///
/// Apart from [parts.dart] because those are *surfaces* — the card, the row, the
/// label every screen sits on — and these are things you operate. The file was
/// heading past the size where either half is findable.
library;

import 'package:flutter/material.dart';
import 'package:grid_theme/grid_theme.dart';

import 'parts.dart';

/// A row of mutually exclusive choices, the selected one in accent.
///
/// For a setting whose options are few, short and worth seeing side by side —
/// four text sizes read as a scale when they sit in a row, and as four unrelated
/// rows when they stack. Anything longer than that belongs in a list.
class SegmentedChoice<T> extends StatelessWidget {
  const SegmentedChoice({
    required this.options,
    required this.selected,
    required this.onPick,
    super.key,
  });

  /// What there is to pick, in order.
  final List<({String label, T value})> options;

  /// Which one is on.
  final T selected;

  /// Picking one.
  final ValueChanged<T> onPick;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final radius = BorderRadius.circular(AppCard.radius);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: AppGlass.rowFill, borderRadius: radius),
      child: Row(
        children: [
          for (final option in options)
            Expanded(
              child: _Segment(
                label: option.label,
                selected: option.value == selected,
                onTap: () => onPick(option.value),
              ),
            ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final radius = BorderRadius.circular(AppCard.radius - 3);
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? AppPalette.accent : Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            // Tall enough for a thumb, per the 44pt rule the primary buttons
            // already follow — minus the 3px the track adds either side.
            padding: const EdgeInsets.symmetric(vertical: 11),
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : AppPalette.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A settings row: what it is on the left, its current value on the right, and
/// the whole row opens the choice.
class SettingRow extends StatelessWidget {
  const SettingRow({
    required this.title,
    required this.value,
    required this.onTap,
    super.key,
  });

  /// What the setting is called.
  final String title;

  /// What it is set to now.
  final String value;

  /// Opening the choice.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return GridListRow(
      onTap: onTap,
      child: Row(
        children: [
          Expanded(child: Text(title, style: theme.textTheme.bodyMedium)),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppPalette.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: AppPalette.textFaint,
          ),
        ],
      ),
    );
  }
}
