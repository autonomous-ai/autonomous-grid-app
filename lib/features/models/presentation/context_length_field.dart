import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/context_length.dart';
import '../logic/models_providers.dart';

/// Advanced context-length setting shown under the model fields before the
/// built-in engine starts. Collapsed by default (it's an advanced knob), so the
/// engine card stays compact; the collapsed header still shows the current
/// value. Expanded, it's a slider from 4k to the model's maximum.
///
/// The maximum comes from `grid ctx --json`, so it never offers more context
/// than the model supports; the slider drags smoothly and snaps to 1k, so any
/// value in between (e.g. 200k) is reachable, not just power-of-two stops. If
/// the maximum can't be read the setting hides and the engine uses its default.
class ContextLengthField extends ConsumerWidget {
  const ContextLengthField({
    super.key,
    required this.model,
    required this.value,
    required this.onChanged,
  });

  /// GGUF filename whose maximum context bounds the slider.
  final String model;

  /// The user's chosen context length in tokens, or null to sit at the default
  /// ([defaultContextLength] for the model's maximum).
  final int? value;

  /// Reports the picked context length (already snapped to 1k) as the user drags.
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final maxContext = ref.watch(modelMaxContextProvider(model));
    return maxContext.when(
      loading: () => const _AdvancedTile(valueLabel: null, child: _ReadingLine()),
      error: (_, _) => const SizedBox.shrink(),
      data: (max) {
        if (max == null || max <= minContextTokens) return const SizedBox.shrink();
        final current = value == null
            ? defaultContextLength(max)
            : value!.clamp(minContextTokens, max);
        return _AdvancedTile(
          valueLabel: formatContextLength(current),
          child: _ContextSlider(
            max: max,
            value: current,
            onChanged: (tokens) => onChanged(snapContextLength(tokens, max)),
          ),
        );
      },
    );
  }
}

/// Collapsible "advanced" container for the setting: an outlined tile titled
/// "Context window" with the current value on the same row, expanding to reveal
/// [child]. Kept to one line so its collapsed height matches the input fields
/// above it, and tucked away until the user wants it.
class _AdvancedTile extends StatelessWidget {
  const _AdvancedTile({required this.valueLabel, required this.child});

  /// Current value shown in the collapsed header, or null while it's being read.
  final String? valueLabel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
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

/// The slider itself: continuous from 4k to the model's maximum with 1k
/// snapping (via the parent's [onChanged]) and the min/max at each end.
class _ContextSlider extends StatelessWidget {
  const _ContextSlider({
    required this.max,
    required this.value,
    required this.onChanged,
  });

  final int max;
  final int value;

  /// Reports the raw (unsnapped) token count mid-drag; the parent snaps it.
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final endLabel = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'How much of your conversation the model can remember and use when it '
          'replies. Higher remembers more but uses more memory.',
          style: endLabel,
        ),
        Slider(
          value: value.toDouble(),
          min: minContextTokens.toDouble(),
          max: max.toDouble(),
          label: formatContextLength(value),
          onChanged: (v) => onChanged(v.round()),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(formatContextLength(minContextTokens), style: endLabel),
              Text(formatContextLength(max), style: endLabel),
            ],
          ),
        ),
      ],
    );
  }
}

/// Shown in the tile while `grid ctx` reads the model's maximum — a brief moment
/// after the model is picked.
class _ReadingLine extends StatelessWidget {
  const _ReadingLine();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 10),
        Text(
          "Reading this model's limit…",
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
