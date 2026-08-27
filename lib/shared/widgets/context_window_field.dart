import 'package:flutter/material.dart';

import '../../core/context_length.dart';
import '../theme/app_theme.dart';
import '../theme/share_page_theme.dart';
import 'app_spinner.dart';

/// The "Memory for context" setting: the name and the value on one row, the
/// sentence under it, and a slider from 4k to [max] beneath both.
///
/// Shared because both engine cards ask the same question and §5 wants one
/// wording and one control for it. They differ only in where [max] comes from —
/// a local model's GGUF, or what an external server reports — and that
/// difference belongs to the caller, not to this widget.
class ContextWindowField extends StatelessWidget {
  const ContextWindowField({
    super.key,
    required this.max,
    required this.value,
    required this.onChanged,
    this.note,
  });

  /// The ceiling: the most this engine can actually serve.
  final int max;

  /// Current value in tokens. Always a real number — the setting has no "unset"
  /// state, because a slider with no position is not a control.
  final int value;

  /// Reports the picked length, already snapped to a clean 1k step.
  final ValueChanged<int> onChanged;

  /// An extra line above the slider, for a caller that knows something about
  /// where [max] came from and whether it can be trusted.
  final String? note;

  @override
  Widget build(BuildContext context) {
    return _SliderAndValue(
      max: max,
      value: value,
      note: note,
      onChanged: (tokens) => onChanged(snapContextLength(tokens, max)),
    );
  }
}

/// The tile while the ceiling is still being read — a brief moment after a model
/// is picked, or while a server is being asked.
class ContextWindowLoadingTile extends StatelessWidget {
  const ContextWindowLoadingTile({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ContextWindowTile(
      valueLabel: null,
      child: Row(
        children: [
          const AppSpinner(),
          const SizedBox(width: 10),
          Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Collapsible "advanced" container: an outlined tile titled "Context window"
/// with the current value on the same row, expanding to reveal [child]. Kept to
/// one line so its collapsed height matches the input fields above it, and
/// tucked away until the user wants it.
class ContextWindowTile extends StatelessWidget {
  const ContextWindowTile({
    super.key,
    required this.valueLabel,
    required this.child,
  });

  /// Current value shown in the collapsed header, or null while it's unknown.
  final String? valueLabel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Reads AppCard tokens, so it must follow theme flips itself.
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Container(
      decoration: BoxDecoration(
        // Recessed like a field, not outlined: this tile sits inside an engine
        // block, and the app draws depth with fill and shadow rather than a
        // stroke. Radius 12 matches the fields it stacks with.
        color: AppCard.inset,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        // Drop ExpansionTile's default divider lines so it reads as one tile.
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          // One-line, input-height header (no two-line title+subtitle).
          minTileHeight: 40,
          dense: true,
          leading: Icon(Icons.settings_outlined, size: 18, color: muted),
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          title: Row(
            children: [
              Text('Context window', style: theme.textTheme.titleSmall),
              const Spacer(),
              Text(
                valueLabel ?? 'Reading limit…',
                style: theme.textTheme.bodyMedium?.copyWith(color: muted),
              ),
            ],
          ),
          children: [child],
        ),
      ),
    );
  }
}

/// The slider from 4k to [max], with the value stated beside the setting's
/// name.
///
/// The value used to be a box you could type into, on the argument that a
/// server launched with `--ctx-size 40960` cannot be matched by dragging. That
/// argument moved out from under it: the endpoint form picks its window from a
/// list now, and a *local* model's window is a choice about memory rather than
/// a number to match — every value the slider offers is one 1k step away from
/// the last, so the drag reaches all of them.
class _SliderAndValue extends StatelessWidget {
  const _SliderAndValue({
    required this.max,
    required this.value,
    required this.note,
    required this.onChanged,
  });

  final int max;
  final int value;
  final String? note;

  /// Reports the raw (unsnapped) token count; the parent snaps and clamps it.
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Memory for context', style: ShareType.fieldLabel),
                  Text(
                    'How much of a conversation the model can hold in mind. '
                    'More context, more RAM.',
                    style: ShareType.note,
                  ),
                  if (note case final line?) ...[
                    const SizedBox(height: 4),
                    Text(line, style: ShareType.note),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 16),
            _ValuePill(tokens: value),
          ],
        ),
        SliderTheme(
          // The design's slider: a 5px track, and a white thumb ringed in
          // accent rather than filled with it. Material's default is a fatter
          // track and a solid dot, which on this page read as a different
          // family of control from everything around it.
          data: SliderThemeData(
            trackHeight: 5,
            activeTrackColor: SharePalette.accent,
            inactiveTrackColor: SharePalette.track,
            thumbColor: Colors.white,
            overlayColor: SharePalette.accentRing,
            thumbShape: const _RingThumb(),
            trackShape: const RoundedRectSliderTrackShape(),
          ),
          child: Slider(
            value: value.toDouble().clamp(
              minContextTokens.toDouble(),
              max.toDouble(),
            ),
            min: minContextTokens.toDouble(),
            max: max.toDouble(),
            label: formatContextLength(value),
            // Edge to edge, as the design draws it. Material insets a slider by
            // the width of its own thumb so the handle never overhangs its box;
            // here that left the track short of both margins and the end marks
            // pointing at nothing. The thumb's 8px does overhang now, and the
            // section's 20px padding is what absorbs it.
            padding: EdgeInsets.zero,
            onChanged: (v) => onChanged(v.round()),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Text(
              '${formatContextLength(minContextTokens)} · lightest',
              style: ShareType.note,
            ),
            const Spacer(),
            Text(
              '${formatContextLength(max)} · heaviest',
              style: ShareType.note,
            ),
          ],
        ),
      ],
    );
  }
}

/// The window as the reader reads it: "200k tokens" on a quiet chip.
class _ValuePill extends StatelessWidget {
  const _ValuePill({required this.tokens});

  final int tokens;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: SharePalette.badgeFill,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        '${formatContextLength(tokens)} tokens',
        style: TextStyle(
          fontSize: 14,
          fontWeight: AppFont.semibold,
          color: SharePalette.ink,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// The design's slider handle: white, ringed in accent, with a soft drop.
///
/// Material's `RoundSliderThumbShape` fills the thumb with the active colour,
/// which reads as a dot *on* the track rather than a handle *over* it.
class _RingThumb extends SliderComponentShape {
  const _RingThumb();

  static const double _radius = 8;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      const Size.fromRadius(_radius);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    canvas.drawCircle(
      center.translate(0, 1),
      _radius,
      Paint()
        ..color = SharePalette.ink.withValues(alpha: 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
    canvas.drawCircle(center, _radius, Paint()..color = Colors.white);
    canvas.drawCircle(
      center,
      _radius - 0.75,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = SharePalette.accent,
    );
  }
}
