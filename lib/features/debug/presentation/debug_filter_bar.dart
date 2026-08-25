import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/pill_choice.dart';

/// One lens in a [DebugFilterBar]: what it is called, how many rows it holds,
/// and what selecting it does.
class FilterLens {
  const FilterLens({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
    this.danger = false,
    this.hideWhenEmpty = false,
  });

  final String label;

  /// Live count, shown as a dimmer trailing figure so "is anything red?" is
  /// answered before the list below is even read.
  final int count;

  final bool selected;
  final VoidCallback onTap;

  /// Tints the count red once it is non-zero — for the failure lens.
  final bool danger;

  /// Drop this lens while its count is zero. An always-there "Failed 0" pill
  /// trains the eye to ignore it; it comes back the moment something fails, and
  /// never vanishes from under a user who has it selected.
  final bool hideWhenEmpty;
}

/// The row of status lenses above a developer tab's list.
///
/// Shared by Debug and Tracking, which had the same bar down to the count
/// colours — one of them would have been edited alone within a week.
class DebugFilterBar extends StatelessWidget {
  const DebugFilterBar({super.key, required this.lenses});

  final List<FilterLens> lenses;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final lens in lenses)
          if (!lens.hideWhenEmpty || lens.count > 0 || lens.selected)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: PillChoice(
                selected: lens.selected,
                onTap: lens.onTap,
                label: _FilterLabel(lens: lens),
              ),
            ),
      ],
    );
  }
}

/// A pill's text plus a dimmer trailing count — the count reads as metadata,
/// not as part of the label.
class _FilterLabel extends StatelessWidget {
  const _FilterLabel({required this.lens});

  final FilterLens lens;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppPalette tokens — follow theme flips.
    // On a selected (accent) pill the count sits on white; otherwise it's a
    // faint trailing figure, red when it's the failure lens carrying a hit.
    final countColor = lens.selected
        ? Colors.white70
        : lens.danger && lens.count > 0
        ? Theme.of(context).colorScheme.error
        : AppPalette.textFaint;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(lens.label),
        const SizedBox(width: 6),
        Text(
          '${lens.count}',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: AppFont.medium,
            color: countColor,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
