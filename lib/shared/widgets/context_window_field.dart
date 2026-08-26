import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/context_length.dart';
import '../theme/app_theme.dart';
import 'app_spinner.dart';

/// The "Context window" setting: a collapsed tile showing the current value,
/// opening onto a slider from 4k to [max].
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
    return ContextWindowTile(
      valueLabel: formatContextLength(value),
      child: _SliderAndBox(
        max: max,
        value: value,
        note: note,
        onChanged: (tokens) => onChanged(snapContextLength(tokens, max)),
      ),
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

/// The slider from 4k to [max], plus a box for typing the exact number.
///
/// Two controls for one value, because they answer different needs: dragging is
/// how you find a size when you don't have one in mind, and typing is how you
/// enter the number your server was actually launched with. A slider alone
/// cannot reliably land on 40960, and a box alone gives no sense of the range.
class _SliderAndBox extends StatefulWidget {
  const _SliderAndBox({
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
  State<_SliderAndBox> createState() => _SliderAndBoxState();
}

class _SliderAndBoxState extends State<_SliderAndBox> {
  late final _typed = TextEditingController(text: '${widget.value}');
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      // Committing on blur as well as on Enter: a person who types a number and
      // then reaches for Start has said what they meant, and losing it there
      // would be silent.
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_SliderAndBox old) {
    super.didUpdateWidget(old);
    // Follow the slider, but never rewrite the box under someone's cursor.
    if (widget.value != old.value && !_focus.hasFocus) {
      _typed.text = '${widget.value}';
    }
  }

  @override
  void dispose() {
    _typed.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Take what was typed, or put back what the value actually is.
  ///
  /// Nothing is reported per keystroke: typing `8192` passes through `8`, and a
  /// value clamped to the 4k floor mid-word would fight the person typing it.
  void _commit() {
    final typed = int.tryParse(_typed.text.trim());
    if (typed == null) {
      _typed.text = '${widget.value}';
      return;
    }
    final settled = snapContextLength(typed, widget.max);
    _typed.text = '$settled';
    if (settled != widget.value) widget.onChanged(settled);
  }

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
        if (widget.note case final line?) ...[
          const SizedBox(height: 4),
          Text(line, style: endLabel),
        ],
        Row(
          children: [
            Expanded(
              child: Slider(
                value: widget.value.toDouble().clamp(
                  minContextTokens.toDouble(),
                  widget.max.toDouble(),
                ),
                min: minContextTokens.toDouble(),
                max: widget.max.toDouble(),
                label: formatContextLength(widget.value),
                onChanged: (v) => widget.onChanged(v.round()),
              ),
            ),
            const SizedBox(width: 8),
            _TokenBox(controller: _typed, focus: _focus, onCommit: _commit),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Text(formatContextLength(minContextTokens), style: endLabel),
              const Spacer(),
              Text(formatContextLength(widget.max), style: endLabel),
            ],
          ),
        ),
      ],
    );
  }
}

/// The exact-number box: digits only, wide enough for the largest window the
/// slider can reach.
///
/// Sized for **seven digits** (1048576), not six: a 92px box fitted `204800`
/// and then clipped a megabyte-scale number into `2048C…`, which is not a
/// wrong number on screen so much as a plausible-looking one.
///
/// No unit suffix inside the box, for the same reason — it competes with the
/// digits for a width that has to hold the worst case, and the tile it sits in
/// is already titled "Context window" with the k/M scale at both ends of the
/// slider.
class _TokenBox extends StatelessWidget {
  const _TokenBox({
    required this.controller,
    required this.focus,
    required this.onCommit,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final VoidCallback onCommit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 104,
      child: TextField(
        controller: controller,
        focusNode: focus,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        textAlign: TextAlign.right,
        // Tabular figures: the number changes as the slider moves, and
        // proportional digits make it jitter sideways while it does.
        style: theme.textTheme.bodyMedium?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        onSubmitted: (_) => onCommit(),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: AppPalette.cardBg,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 8,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppControl.radius),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}
