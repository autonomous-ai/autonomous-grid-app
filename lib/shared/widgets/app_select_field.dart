import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'labeled_field.dart';

/// What a badge *means*, not what colour it is — the widget maps it to the
/// palette so a verdict reads the same everywhere it appears.
///
/// Only a judgement earns colour. A fact (a quant name, a file size) stays
/// [neutral]: if every badge is tinted, the tint stops carrying information and
/// the row turns into a fruit salad.
enum AppBadgeTone { neutral, positive, warning, danger }

/// A small pill beside an option's label — a version's size, its quantisation,
/// whether it will actually run on this machine.
class AppSelectBadge {
  const AppSelectBadge(this.text, {this.tone = AppBadgeTone.neutral});

  final String text;
  final AppBadgeTone tone;
}

/// One option in an [AppSelectField].
class AppSelectOption<T> {
  const AppSelectOption({
    required this.value,
    required this.label,
    this.detail,
    this.badges = const [],
  });

  final T value;

  /// The row's main line, and what the closed field shows once picked.
  final String label;

  /// An optional second line under [label] — context the choice needs but the
  /// closed field has no room for.
  final String? detail;

  /// Pills rendered beside [label], in both the closed field and the open menu.
  ///
  /// Takes precedence over [detail]'s legacy ` · `-split rendering: a caller
  /// that has to distinguish "runs here" from "too large" needs to say which is
  /// which, and a delimited string can't.
  final List<AppSelectBadge> badges;
}

/// A select control that opens the app's floating menu.
///
/// Replaces `DropdownButtonFormField`, which cannot be made to match: Material
/// renders its popup itself, anchored *over* the field and sized to the field's
/// width, so it arrives edge-to-edge with square corners no matter what
/// `borderRadius`/`elevation` are passed. Beside a [MenuAnchor] menu the two
/// read as different design systems — which is exactly how the Provider and
/// Local-model pickers looked next to the models menu.
///
/// This is the same construction as that menu: a borderless capsule field, and
/// a [MenuAnchor] panel in [appMenuStyle] hanging below it.
class AppSelectField<T> extends StatefulWidget {
  const AppSelectField({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.placeholder = 'Choose…',
    this.showLabel = true,
    this.showDetailInField = true,
    this.fill,
    this.outlined = false,
  });

  /// Whether the closed field repeats the picked option's
  /// [AppSelectOption.detail] beside its label.
  ///
  /// On by default, because the control was built for details that are a
  /// *verdict* — "2.5 GB", "runnable" — which are worth a glance without
  /// opening anything. Turn it off when the detail is a **sentence**: the
  /// closed field is only as wide as the control, so a clause arrives clipped
  /// to "Send work to the grid, an…", which reads as a rendering bug rather
  /// than as help. The open menu still shows it whole, which is where it's
  /// needed — while choosing, not after.
  final bool showDetailInField;

  /// Draw the closed capsule with the same hairline a plain `TextField`
  /// wears, instead of relying on its fill alone.
  ///
  /// For a select sitting directly beneath a bordered text input: without
  /// it the two controls in one form read as different kinds of thing, and
  /// the softer one looks unfinished beside the crisp one.
  final bool outlined;

  /// Overrides the closed field's surface — see [labeledFieldDecoration].
  ///
  /// The default ([AppCard.inset]) is tuned for a field sitting on the page. A
  /// caller that puts this on a *raised* row has to pass the token that recesses
  /// against that row, and the answer differs by theme: measured against
  /// `AppGlass.surfaceFill`, `inset` wins in dark (1.090 vs 1.023) and `cardBg`
  /// wins in light (1.110 vs 1.073). Picking one for both leaves the control
  /// invisible in whichever theme lost.
  final Color? fill;

  /// Sits above the control ([FieldLabel]) — the app doesn't float labels.
  final String label;

  /// Whether to draw [label] above the control.
  ///
  /// Off for a settings row, which names the preference in its own left column:
  /// a second copy of the name would say the same thing twice, and — because it
  /// adds height this control's neighbours don't have — it also knocks a column
  /// of controls out of alignment with each other. [label] is still required
  /// when this is false: it stays the control's accessible name.
  final bool showLabel;

  /// Currently selected value, or null when nothing is picked yet.
  final T? value;

  final List<AppSelectOption<T>> options;
  final ValueChanged<T> onChanged;

  /// Shown when [value] matches no option — an empty selection reads as a
  /// prompt, not as a blank field.
  final String placeholder;

  @override
  State<AppSelectField<T>> createState() => _AppSelectFieldState<T>();
}

class _AppSelectFieldState<T> extends State<AppSelectField<T>> {
  final _menu = MenuController();

  String get _summary {
    for (final option in widget.options) {
      if (option.value == widget.value) return option.label;
    }
    return widget.placeholder;
  }

  String? get _detail {
    for (final option in widget.options) {
      if (option.value == widget.value) return option.detail;
    }
    return null;
  }

  List<AppSelectBadge> get _badges {
    for (final option in widget.options) {
      if (option.value == widget.value) return option.badges;
    }
    return const [];
  }

  bool get _hasSelection =>
      widget.options.any((option) => option.value == widget.value);

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // The menu opens at the field's width rather than shrink-wrapping to the
    // longest label, so a picked value never shifts the panel's edges. Rows
    // carry that width themselves — MenuStyle.minimumSize doesn't widen the
    // panel reliably.
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showLabel) FieldLabel(widget.label),
          MenuAnchor(
            controller: _menu,
            alignmentOffset: const Offset(0, 6),
            style: appMenuStyle(),
            // With the visible label suppressed, the name has to reach a screen
            // reader some other way — a control announced only as its current
            // value ("System") says nothing about what it sets.
            builder: (context, controller, _) => Semantics(
              label: widget.showLabel ? null : widget.label,
              child: _FieldSurface(
                summary: _summary,
                muted: !_hasSelection,
                fill: widget.fill,
                outlined: widget.outlined,
                detail: widget.showDetailInField ? _detail : null,
                badges: _badges,
                onTap: controller.isOpen ? controller.close : controller.open,
              ),
            ),
            menuChildren: [
              for (final option in widget.options)
                _OptionRow<T>(
                  option: option,
                  width: constraints.maxWidth,
                  selected: option.value == widget.value,
                  onTap: () {
                    _menu.close();
                    widget.onChanged(option.value);
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The closed control: the same borderless capsule as every other field, with a
/// disclosure arrow.
class _FieldSurface extends StatelessWidget {
  const _FieldSurface({
    required this.summary,
    required this.muted,
    required this.onTap,
    required this.outlined,
    this.fill,
    this.detail,
    this.badges = const [],
  });

  final String summary;
  final bool muted;
  final VoidCallback onTap;

  /// See [AppSelectField.outlined].
  final bool outlined;

  /// The surface, when the default doesn't recess against what it sits on.
  final Color? fill;

  /// Optional detail line (e.g. "2.5 GB · runnable") rendered as small badges
  /// beside the main text. Used only when [badges] is empty.
  final String? detail;

  final List<AppSelectBadge> badges;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: InputDecorator(
        isEmpty: false,
        decoration: labeledFieldDecoration(
          '',
          fill: fill ?? AppCard.inset,
          outlined: outlined,
          skin: FieldSkinScope.maybeOf(context),
        ),
        child: Row(
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      summary,
                      overflow: TextOverflow.ellipsis,
                      style: muted
                          ? kFieldTextStyle.copyWith(
                              color: AppPalette.textFaint,
                            )
                          : kFieldTextStyle.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                    ),
                  ),
                  // Flexible, not a bare child: a badge holds whatever text the
                  // caller had — "3 parts", but also a sentence like "SF Pro —
                  // what the app is designed in" — and an unconstrained one
                  // overflowed the field by 90px in a narrow window instead of
                  // giving way. It shrinks and ellipsizes now; the menu row
                  // below has the room to show it whole.
                  if (badges.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    for (final badge in badges)
                      Flexible(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: _Badge(badge: badge),
                        ),
                      ),
                  ] else if (detail != null && detail!.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    for (final part in detail!.split(' · '))
                      Flexible(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: _Badge(badge: AppSelectBadge(part)),
                        ),
                      ),
                  ],
                ],
              ),
            ),
            Icon(
              FieldSkinScope.maybeOf(context)?.slimChevron == true
                  ? Icons.keyboard_arrow_down_rounded
                  : Icons.arrow_drop_down,
              // Size 24 (a dropdown's default arrow) so the field matches the
              // theme's field height instead of shrinking to the 18px icon
              // theme.
              size: 24,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// A pill beside an option's label.
///
/// A toned badge is a wash of its status colour, not a filled chip: the ink is
/// the full-strength token and the fill a ~14% tint of it, so it stays pastel in
/// light and doesn't glow on charcoal in dark. The status tokens are the ones
/// the rest of the app already reads as good/caution/bad ([AppPalette.online],
/// [AppPalette.warn], the scheme's error), so a green here means what a green
/// means anywhere else in the window.
class _Badge extends StatelessWidget {
  const _Badge({required this.badge});
  final AppSelectBadge badge;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final tint = switch (badge.tone) {
      AppBadgeTone.neutral => null,
      AppBadgeTone.positive => AppPalette.online,
      AppBadgeTone.warning => AppPalette.warn,
      AppBadgeTone.danger => theme.colorScheme.error,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: tint?.withValues(alpha: 0.14) ?? AppSurface.selectedFill,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: tint?.withValues(alpha: 0.28) ?? AppPalette.divider,
        ),
      ),
      child: Text(
        badge.text,
        // One line, ellipsized: a pill is a glance, and in a field only as wide
        // as the control it sits in there may not be room for the whole of it.
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: tint ?? AppPalette.textSecondary,
          fontSize: 11,
          fontWeight: tint == null ? FontWeight.w400 : FontWeight.w600,
        ),
      ),
    );
  }
}

/// Gutter between a row and the panel's edge, so the hover highlight reads as a
/// rounded pill inside the menu rather than a full-bleed band.
const _rowGutter = 6.0;

/// Padding inside a row's own highlight.
const _rowInnerPad = 9.0;

/// Fixed slot for the leading tick, so labels line up whether or not a row is
/// the selected one.
const _rowTickSlot = 16.0;
const _rowTickGap = 9.0;

/// One row in the panel — deliberately **not** a bare [MenuItemButton].
///
/// `MenuItemButton` is unthemed in this app (there is no `menuButtonTheme`), so
/// left alone it takes Material's M3 defaults, which disagree with the design
/// system on four counts: square corners (radius 0 vs 8), 14pt `labelLarge`
/// text (vs the app's 13), Material's grey `onSurface`-at-8% hover (vs
/// `AppSurface.hoverFill`), and an ink ripple the app's menus suppress.
///
/// So this mirrors the chat model picker's `_OptionRow` construction instead:
/// an `InkWell` with the app's hover token and no splash, over an `Ink` that
/// carries the selected wash — the shape every other polished menu in the app
/// uses.
class _OptionRow<T> extends StatelessWidget {
  const _OptionRow({
    required this.option,
    required this.width,
    required this.selected,
    required this.onTap,
  });

  final AppSelectOption<T> option;
  final double width;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final radius = BorderRadius.circular(AppControl.radius);
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: _rowGutter,
          vertical: 1,
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: radius,
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            hoverColor: AppSurface.hoverFill,
            // The app's menus don't ripple — a splash on a list of choices
            // reads as a touch target, not a pointer one.
            splashFactory: NoSplash.splashFactory,
            child: Ink(
              decoration: BoxDecoration(
                color: selected ? AppSurface.accentWash : Colors.transparent,
                borderRadius: radius,
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: _rowInnerPad,
                vertical: 8,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _Lines(option: option, selected: selected),
                  ),
                  const SizedBox(width: _rowTickGap),
                  SizedBox(
                    width: _rowTickSlot,
                    // Kept in the layout even when unselected so labels don't
                    // shift as the selection moves.
                    child: selected
                        ? Icon(
                            Icons.check_rounded,
                            size: AppControl.iconSize,
                            color: AppPalette.accentMuted,
                          )
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A row's label, and its detail line when it has one.
class _Lines<T> extends StatelessWidget {
  const _Lines({required this.option, required this.selected});

  final AppSelectOption<T> option;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          option.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          // 13/1.2 — the app's control type, not Material's 14pt labelLarge.
          style: TextStyle(
            fontSize: AppControl.fontSize,
            height: 1.2,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: AppPalette.textPrimary,
          ),
        ),
        // The same pills the closed field shows — the verdict that decides which
        // option to pick has to be visible *while* picking, not only after.
        if (option.badges.isNotEmpty) ...[
          const SizedBox(height: 5),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [for (final badge in option.badges) _Badge(badge: badge)],
          ),
        ] else if (option.detail case final detail?) ...[
          const SizedBox(height: 3),
          Text(
            detail,
            // Wraps. A detail here is a *sentence* explaining what the
            // option does, and one line of a menu's width cannot hold one:
            // it arrived clipped at "or start an AI node to powe…", losing
            // the clause that made it worth reading. Three lines is enough
            // for the longest rule; the cap is a backstop, not a budget.
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              height: 1.28,
              color: AppPalette.textSecondary,
            ),
          ),
        ],
      ],
    );
  }
}
