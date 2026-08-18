import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A flat, unfilled dropdown trigger for the composer's toolbar — the shared
/// shape of the model, agent and access controls that sit under the text box.
///
/// Chrome, not a call to action: transparent, unrimmed and shadowless, it lets
/// the composer's own surface carry it and reports a choice rather than shouting
/// for one. [leading] is the choice's mark (a tinted glyph, or an agent's logo),
/// [label] its name, and a caret says it opens a menu.
///
/// One widget so the three controls can't drift apart in height, radius or weight
/// the way three hand-rolled pills did — one filled, one rimmed, one flat.
class ComposerTrigger extends StatelessWidget {
  const ComposerTrigger({
    super.key,
    required this.label,
    required this.onTap,
    this.leading,
    this.tooltip,
    this.borderColor,
  });

  /// The mark shown before the label — a small [Icon], or an agent's logo. Null
  /// when there's nothing to mark yet (a model not chosen).
  final Widget? leading;

  final String label;

  /// Hover text; the button carries none when null.
  final String? tooltip;

  /// A rim colour for the pill, when it needs to read as "fix me" rather than a
  /// quiet choice — e.g. a model pill with an image attached the model can't
  /// read. Null (the norm) leaves the pill rimless.
  final Color? borderColor;

  final VoidCallback onTap;

  /// Narrower than this and the label goes: 20px of padding, a ~14px mark, its
  /// 5px gap and a 16px caret leave under 25px for words, which is two letters
  /// and an ellipsis. A mark that means something beats a truncation that
  /// doesn't — and the name is still one hover away (see [build]).
  static const _labelFloor = 82.0;

  /// Narrower still and the caret goes too, leaving the mark alone. A caret is
  /// 16px of "this opens a menu" that a 40px pill cannot afford.
  static const _caretFloor = 58.0;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppPalette tokens — follow theme flips.
    return LayoutBuilder(
      builder: (context, constraints) => _button(context, constraints.maxWidth),
    );
  }

  Widget _button(BuildContext context, double available) {
    final border = borderColor;
    // An unbounded box is a roomy one: the composer caps these with a
    // `ConstrainedBox`, so a finite width here is the real allowance.
    final showLabel = !available.isFinite || available >= _labelFloor;
    final showCaret = !available.isFinite || available >= _caretFloor;
    final button = OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: AppPalette.textPrimary,
        backgroundColor: Colors.transparent,
        side: border == null
            ? BorderSide.none
            : BorderSide(color: border.withValues(alpha: 0.6)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppControl.radius),
        ),
        padding: AppControl.paddingSmall,
        // Pin the height at both ends so the button can't inflate to the 48px its
        // own vertical padding would otherwise force — but leave the width free
        // (min 0), so the pill hugs its label instead of stretching to fill the
        // box it's dropped in. `Size.fromHeight` sets minWidth to infinity, which
        // made these fill their maxWidth cap and trail empty space to the right.
        minimumSize: const Size(0, AppControl.heightSmall),
        maximumSize: const Size.fromHeight(AppControl.heightSmall),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        splashFactory: NoSplash.splashFactory,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[
            leading!,
            if (showLabel) const SizedBox(width: 5),
          ],
          if (showLabel)
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: TextStyle(
                  fontSize: 12,
                  color: border == null
                      ? null
                      : Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          // The mark alone still needs *something* when there is no mark to
          // show — a pill with neither would be an empty box.
          if (!showLabel && leading == null)
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          if (showCaret) ...[
            const SizedBox(width: 1),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 15,
              color: border == null
                  ? AppPalette.textFaint
                  : Theme.of(context).colorScheme.error,
            ),
          ],
        ],
      ),
    );
    // Once the label is off, the tooltip is the only place the name is left — so
    // it stops being optional.
    final hint = tooltip ?? (showLabel ? null : label);
    if (hint == null) return button;
    return Tooltip(message: hint, child: button);
  }
}
