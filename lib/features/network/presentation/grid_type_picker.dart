import 'package:flutter/material.dart';

import '../../../infrastructure/api/models/managed_network.dart';
import '../../../shared/theme/app_theme.dart';

/// The grid's visibility, as a two-way segmented control.
///
/// It was a dropdown, which is the wrong instrument for two options: it costs a
/// click, a menu, a read and a second click to flip what is really a switch —
/// and until that first click it *hides* the other choice, so you couldn't tell
/// a private grid was even possible. Laid out flat, both options are readable
/// before you touch anything, and picking one is a single click.
///
/// It also stopped a dropdown from wearing [InputDecoration], the recipe for a
/// box you *type* in. That's why it read as a disabled text field: same fill,
/// same rim, no affordance saying it opens.
///
/// A recessed groove with the picked cell lifted in accent — the app's segmented
/// control, built here rather than shared: the two places that ask this question
/// (the create dialog, the first-run grid screen) are wide rows with two
/// glyph-less cells, which is nothing like the narrow, glyph-stacked cells the
/// pattern came from. Shared between those two so the same question can't grow
/// two sets of words (§5).
class GridTypePicker extends StatelessWidget {
  const GridTypePicker({
    super.key,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final ManagedNetworkType value;
  final bool enabled;
  final ValueChanged<ManagedNetworkType> onChanged;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppSurface.recess,
          borderRadius: BorderRadius.circular(AppControl.radius + 2),
        ),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Row(
            children: [
              for (final type in ManagedNetworkType.values)
                Expanded(
                  child: _TypeSegment(
                    label: type.label,
                    selected: type == value,
                    onTap: enabled ? () => onChanged(type) : null,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One cell of [GridTypePicker].
class _TypeSegment extends StatelessWidget {
  const _TypeSegment({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? Colors.white : AppPalette.textSecondary;
    return Material(
      color: selected ? AppPalette.accent : Colors.transparent,
      borderRadius: BorderRadius.circular(AppControl.radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppControl.radius),
        onTap: onTap,
        child: SizedBox(
          height: AppControl.height,
          child: Center(
            child: Text(
              label,
              maxLines: 1,
              style: TextStyle(
                fontFamily: AppFont.sans,
                fontFamilyFallback: AppFont.sansFallback,
                fontSize: AppControl.fontSize,
                fontWeight: FontWeight.w600,
                color: foreground,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
