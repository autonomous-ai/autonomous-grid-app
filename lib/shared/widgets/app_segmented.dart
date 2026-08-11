import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// One tab of an [AppSegmented] — a label, and optionally a glyph before it and
/// a count after it in a quieter ink.
class SegmentSpec {
  const SegmentSpec({required this.label, this.count, this.icon});

  final String label;

  /// Shown after the label ("Installed 3"). Null hides it entirely rather than
  /// printing a `0` that reads as a broken counter.
  final int? count;

  /// Shown before the label, in the segment's own ink so it lights with the
  /// text rather than staying dim under the pointer. Null draws none — a
  /// toolbar of short words does not need one, and the top-level Home/Code
  /// switch does.
  final IconData? icon;
}

/// A macOS-style segmented control: a recessed track with the selected segment
/// riding on a raised chip.
///
/// Built here rather than from [SegmentedButton], which draws Material's outlined
/// pill — a visible border (rule 1 forbids it), stadium corners on a desktop, and
/// an ink ripple the app disables everywhere else.
///
/// ### Why the chip is [AppGlass.surfaceFill] and not [AppGlass.bubbleFill]
///
/// Measured against the track ([AppSurface.recess] composited over the dialog):
///
/// ```
/// dark   track #2B2B2B vs surfaceFill #202020 = 1.151 : 1
/// dark   track #2B2B2B vs bubbleFill  #242424 = 1.096 : 1
/// light  track #F7F7F7 vs surfaceFill #FFFFFF = 1.071 : 1
/// light  track #F7F7F7 vs bubbleFill  #F3F3F1 = 1.037 : 1   ← invisible
/// ```
///
/// `bubbleFill` moves the *wrong way* in light (it darkens toward the track), so
/// the chip vanishes. `surfaceFill` lifts in both. Neither number is large on its
/// own — as §1 of the design system puts it, fill can't separate layers, shadow
/// can — hence [AppGlass.cardShadow] on the chip.
///
/// Selection is marked three ways (chip fill + shadow + `w600` ink), never by
/// colour alone.
class AppSegmented extends StatelessWidget {
  const AppSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  final List<SegmentSpec> segments;
  final int selected;
  final ValueChanged<int> onChanged;

  /// Track corner. The chip inside drops to 6 — a child is never rounder than
  /// its parent (rule 3).
  static const _trackRadius = 8.0;
  static const _chipRadius = 6.0;

  /// Track padding around the chip, on all four sides.
  static const _inset = 2.0;

  /// The chip's height, chosen so the *track* lands on [AppControl.height].
  ///
  /// The track is what shares a toolbar row with a search field, and the two
  /// have to be the same height or their edges disagree. Sizing the chip first
  /// and letting the track fall where it may gave 24 + 2×2 = **28** against the
  /// field's **32**: centres aligned, edges 2px out at top and bottom — visible
  /// in a screenshot, and invisible to a test that only compared centres.
  static const _chipHeight = AppControl.height - _inset * 2;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppSurface/AppGlass/AppPalette tokens.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppSurface.recess,
        borderRadius: BorderRadius.circular(_trackRadius),
      ),
      child: Padding(
        padding: const EdgeInsets.all(_inset),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < segments.length; i++) ...[
              if (i > 0) const SizedBox(width: _inset),
              _Segment(
                spec: segments[i],
                selected: i == selected,
                onTap: () => onChanged(i),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Segment extends StatefulWidget {
  const _Segment({
    required this.spec,
    required this.selected,
    required this.onTap,
  });

  final SegmentSpec spec;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_Segment> createState() => _SegmentState();
}

class _SegmentState extends State<_Segment> {
  // Tracked here rather than on the row: an unselected segment has to lift its
  // own ink under the pointer, the way every other affordance in the app does.
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final selected = widget.selected;
    // Hover climbs an unselected label to textPrimary; a glyph that stays dim
    // while the pointer is on it reads as decoration.
    final ink = selected || _hovered
        ? AppPalette.textPrimary
        : AppPalette.textSecondary;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppMotion.hover,
          curve: AppMotion.curve,
          height: AppSegmented._chipHeight,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: selected
                ? AppGlass.surfaceFill
                : (_hovered ? AppSurface.hoverFill : Colors.transparent),
            borderRadius: BorderRadius.circular(AppSegmented._chipRadius),
            boxShadow: selected ? AppGlass.cardShadow : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.spec.icon != null) ...[
                Icon(widget.spec.icon, size: 14, color: ink),
                const SizedBox(width: 6),
              ],
              Text(
                widget.spec.label,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.2,
                  fontWeight: selected ? FontWeight.w600 : AppFont.medium,
                  color: ink,
                ),
              ),
              if (widget.spec.count != null) ...[
                const SizedBox(width: 5),
                Text(
                  '${widget.spec.count}',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.2,
                    fontWeight: AppFont.medium,
                    // textSecondary, not the textFaint an ExtensionSectionHeader
                    // uses for the same-looking number. That one is micro-type
                    // over a page; this one rides a recessed track, where faint
                    // measures **2.76:1** in dark and 3.11 in light — under 4.5
                    // for a figure that carries meaning ("1 model installed").
                    // Secondary reaches 5.93 / 5.80 on the track and 6.82 / 6.21
                    // on the selected chip.
                    color: AppPalette.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
