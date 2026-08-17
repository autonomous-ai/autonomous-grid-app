import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/anchored_menu_position.dart';
import '../../../shared/widgets/composer_trigger.dart';
import '../../../shared/widgets/labeled_field.dart';

/// The composer's control for how much the assistant may do to this computer.
///
/// It sits next to the model, because it's the other half of "what happens when I
/// press Send": who answers, and what they're allowed to touch. The choice sticks
/// until it's changed, and every menu line says plainly what it costs — including
/// the one that stops asking altogether.
///
/// Told what to show and given somewhere to send a pick, rather than reaching for
/// the state itself: what a pick means depends on the chat it was made in, and
/// that is the chat feature's business, not this widget's.
class ApprovalPicker extends ConsumerStatefulWidget {
  const ApprovalPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  /// The mode in force where this picker is shown.
  final AgentApprovalMode value;

  /// Called with the mode the user picked.
  final ValueChanged<AgentApprovalMode> onChanged;

  @override
  ConsumerState<ApprovalPicker> createState() => _ApprovalPickerState();
}

/// The menu's width, and the gutter its rows are inset by. The rows used to
/// carry a hand-computed `width: 324` — the menu's 340 minus twice this gutter —
/// so changing either number silently mis-sized the rows against the panel they
/// sit in. Derive one from the other instead.
const _menuWidth = 340.0;
const _rowGutter = 8.0;
const _rowInnerPad = 10.0;

/// The rest of a row's box, spelled out because [_menuSize] measures the text
/// inside it: the gutter above and below each row, the padding on the row's
/// trailing edge, the icon chip and the gap after it, and the tick column with
/// the gap before it.
const _rowOuterPadV = 3.0;
const _rowTrailPad = 8.0;
const _iconChip = 30.0;
const _iconGap = 10.0;
const _tickGap = 8.0;
const _tickWidth = 18.0;
const _titleDetailGap = 3.0;

/// The panel's own vertical padding — [appMenuStyle]'s `vertical: 5`, read off
/// that style rather than guessed. Same note in `grid_model_picker`: the two
/// drifting apart is what pushes a menu off its button.
const _menuPadding = 5.0;

/// The air the panel keeps from the window edge, passed to
/// [anchoredMenuPosition] and used to work out how tall it may draw.
const _menuMargin = 8.0;

/// The width a row's detail text wraps inside, derived through the same boxes
/// the row builds: panel minus its gutters, minus the row's own padding, minus
/// the icon chip and the tick column.
const _detailWidth =
    _menuWidth -
    _rowGutter * 2 -
    _rowInnerPad -
    _rowTrailPad -
    _iconChip -
    _iconGap -
    _tickGap -
    _tickWidth;

/// The heading's own box: it lines up on the rows' icon chips (their outer
/// gutter plus their inner pad) and keeps its own air above and below. Named so
/// [_headingHeight] and [_MenuHeading] can't drift apart.
const _headingPadTop = 8.0;
const _headingPadBottom = 9.0;
const _headingPadRight = 14.0;

/// The width the heading wraps inside — its own padding, not a row's.
const _headingWidth =
    _menuWidth - (_rowGutter + _rowInnerPad) - _headingPadRight;

/// A menu row's corner. One radius, not the 11 that used to be typed twice in
/// the same widget for the row's shape and its decoration.
final _rowRadius = BorderRadius.circular(AppControl.radius);

/// The heading, and the style both [_menuSize] and [_MenuHeading] resolve it
/// with.
///
/// Shared rather than typed in both places: the panel is placed by laying this
/// exact string out, so a heading reworded or resized in the widget alone would
/// place a panel of the wrong height. And built off the theme rather than as a
/// bare `TextStyle`, because a bare one *inherits* the ambient default — the
/// string that draws would carry a family and tracking the measured string
/// doesn't, and would wrap somewhere else. The colour is applied where it is
/// drawn: a token resolved at paint time can't sit in a const.
const _headingText = 'What may the assistant do on this computer?';
const _headingSize = 11.5;

TextStyle _headingStyle(ThemeData theme) => theme.textTheme.bodySmall!.copyWith(
  fontSize: _headingSize,
  fontWeight: AppFont.medium,
  letterSpacing: AppFont.trackingFor(_headingSize),
);

/// The tallest this panel may draw: the window, less the margin it keeps at both
/// edges.
///
/// Its own cap rather than [AppControl.menuMaxHeight]'s 240, because this menu
/// is not a list that may be scrolled past — it is four fixed choices about what
/// the assistant may do to the computer, and at 240 the panel drew the heading
/// and two of them. The other two, including the one that stops asking
/// altogether, were below the fold of a panel with no visible scrollbar: a
/// safety control that hides its safest and most dangerous options.
double _menuMaxHeight(BuildContext context) =>
    MediaQuery.sizeOf(context).height - _menuMargin * 2;

/// What the menu will measure, so [anchoredMenuPosition] lands it on the pill.
///
/// `MenuStyle.alignment` + `alignmentOffset` — what this used before — reads as
/// "top-left on the pill's top-left, then grow *down*", which drives a tall panel
/// through the composer; Flutter shoves it up and sideways to fit the window and
/// the result sits wherever the clamp left it. Same note in `agent_picker`.
///
/// Every part is *measured*, not estimated: the details are sentences of
/// different lengths, so the rows are not the same height as each other, and a
/// row that wraps to a third line at the user's font size is not the height it
/// is on this machine. A flat per-row guess is what put a 70px estimate on rows
/// that draw ~81 and ~98.
Size _menuSize(BuildContext context) {
  final theme = Theme.of(context);
  final scaler = MediaQuery.textScalerOf(context);
  final title = _titleStyle(theme);
  final detail = _detailStyle(theme);

  var height = _menuPadding * 2 + _headingHeight(theme, scaler);
  for (final mode in AgentApprovalMode.values) {
    final text =
        _textHeight(approvalLabel(mode), title, _detailWidth, scaler, 1) +
        _titleDetailGap +
        _textHeight(approvalDetail(mode), detail, _detailWidth, scaler, null);
    height += _rowOuterPadV * 2 + _rowInnerPad * 2 + math.max(_iconChip, text);
  }
  return Size(_menuWidth, height);
}

TextStyle _titleStyle(ThemeData theme) => theme.textTheme.bodyMedium!.copyWith(
  fontWeight: FontWeight.w600,
  height: 1.16,
);

TextStyle _detailStyle(ThemeData theme) =>
    theme.textTheme.bodySmall!.copyWith(height: 1.28);

double _headingHeight(ThemeData theme, TextScaler scaler) =>
    _headingPadTop +
    _headingPadBottom +
    _textHeight(
      _headingText,
      _headingStyle(theme),
      _headingWidth,
      scaler,
      null,
    );

/// What a line box of [text] occupies at [style], laid out in [maxWidth].
double _textHeight(
  String text,
  TextStyle style,
  double maxWidth,
  TextScaler scaler,
  int? maxLines,
) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: maxLines,
  )..layout(maxWidth: maxWidth);
  return painter.height;
}

class _ApprovalPickerState extends ConsumerState<ApprovalPicker> {
  final _menu = MenuController();

  void _select(AgentApprovalMode mode) {
    widget.onChanged(mode);
    _menu.close();
  }

  void _toggleMenu(BuildContext context, MenuController controller) {
    if (controller.isOpen) {
      controller.close();
      return;
    }
    controller.open(
      // Positioned, not aligned — see [_menuSize] for why.
      position: anchoredMenuPosition(
        context,
        menuSize: _menuSize(context),
        margin: _menuMargin,
        gap: AppControl.menuGap,
        // The pill sits at the bottom of the window, so the menu opens upward;
        // `anchoredMenuPosition` drops back below if it won't fit.
        preferAbove: true,
        // The same cap the panel is drawn with in `build` — placement sums the
        // height the panel is about to take, so the two clamping to different
        // numbers is exactly what lifts a menu clear of its button.
        maxHeight: _menuMaxHeight(context),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // `appMenuStyle` reads palette tokens; follow theme flips.
    AppTheme.watch(context);
    final current = widget.value;
    return MenuAnchor(
      controller: _menu,
      // The shared recipe — see the same note on the agent pill beside this one
      // — with its 240 cap lifted: see [_menuMaxHeight] for why this panel is
      // the one menu in the app that may draw as tall as its content.
      style: appMenuStyle().copyWith(
        maximumSize: WidgetStatePropertyAll(
          Size.fromHeight(_menuMaxHeight(context)),
        ),
      ),
      menuChildren: [
        const SizedBox(width: _menuWidth, child: _MenuHeading()),
        for (final mode in AgentApprovalMode.values)
          _ModeItem(
            mode: mode,
            selected: mode == current,
            onTap: () => _select(mode),
          ),
      ],
      builder: (context, controller, _) => ComposerTrigger(
        label: approvalLabel(current),
        tooltip: approvalDetail(current),
        // The icon alone carries the mode (orange for Full access); the pill
        // itself stays neutral, like every other control in the composer.
        leading: Icon(
          approvalIcon(current),
          size: 13,
          color: approvalColor(current),
        ),
        onTap: () => _toggleMenu(context, controller),
      ),
    );
  }
}

class _MenuHeading extends StatelessWidget {
  const _MenuHeading();

  @override
  Widget build(BuildContext context) {
    // Menu content — detached from the anchor's rebuilds; watch theme itself.
    AppTheme.watch(context);
    return Padding(
      // Lines up on the rows' icon chips: their outer gutter plus their inner
      // pad. Spelled as the sum so it tracks the row when either changes — it
      // used to be the hand-added answer, 18.
      padding: const EdgeInsets.fromLTRB(
        _rowGutter + _rowInnerPad,
        _headingPadTop,
        _headingPadRight,
        _headingPadBottom,
      ),
      child: Text(
        _headingText,
        style: _headingStyle(
          Theme.of(context),
        ).copyWith(color: AppPalette.textFaint),
      ),
    );
  }
}

/// One mode: what it is, what it means, and a tick when it's the one in force.
///
/// Stateful for the hover tint on the icon chip — the row's own overlay is drawn
/// by [MenuItemButton] above this content, so the chip can't read it and has to
/// track the pointer itself.
class _ModeItem extends StatefulWidget {
  const _ModeItem({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final AgentApprovalMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ModeItem> createState() => _ModeItemState();
}

class _ModeItemState extends State<_ModeItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // Menu content — detached from the anchor's rebuilds; watch theme itself.
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final mode = widget.mode;
    final selected = widget.selected;
    return MenuItemButton(
      onPressed: widget.onTap,
      onHover: (h) => setState(() => _hovered = h),
      style: ButtonStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
        overlayColor: WidgetStatePropertyAll(AppSurface.hoverFill),
        // The ripple would spread across a 324px row inside a menu — the least
        // macOS thing on the page. The wash below is the whole response.
        splashFactory: NoSplash.splashFactory,
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: _rowRadius),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: _rowGutter,
          vertical: 3,
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          width: _menuWidth - _rowGutter * 2,
          padding: const EdgeInsets.fromLTRB(
            _rowInnerPad,
            _rowInnerPad,
            8,
            _rowInnerPad,
          ),
          decoration: BoxDecoration(
            // Wash + ticked disc, and no rim: the rim made this read as a button
            // dropped into the menu rather than as the row you're on, and the
            // wash already carries the accent that the disc then confirms.
            color: selected ? AppSurface.accentWash : Colors.transparent,
            borderRadius: _rowRadius,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ModeIcon(mode: mode, hovered: _hovered),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            approvalLabel(mode),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            // The same styles [_menuSize] lays out to place the
                            // panel — restyling the row here alone would move
                            // the menu off its pill.
                            style: _titleStyle(theme),
                          ),
                        ),
                        // The whole detail line used to be warn-orange, which
                        // read as an error rather than as power, and left no
                        // colour free to mark the part that actually bites. The
                        // warning is one fact — say it once, here.
                        if (mode == AgentApprovalMode.full) ...[
                          const SizedBox(width: 6),
                          const _NoUndoBadge(),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      approvalDetail(mode),
                      style: _detailStyle(
                        theme,
                      ).copyWith(color: AppPalette.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 18,
                // The disc matches the rim, not the mode: on the "Ask" row the
                // mode's own accent would be the wash's colour sitting on the
                // wash, and the tick would sink into it.
                child: selected
                    ? Container(
                        width: 18,
                        height: 18,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppPalette.accentMuted,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.check_rounded,
                          size: 12,
                          color: Colors.white,
                        ),
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The one-word cost of [AgentApprovalMode.full], as a chip beside its name.
class _NoUndoBadge extends StatelessWidget {
  const _NoUndoBadge();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads colour tokens; follow theme flips.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: AppPalette.warn.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        'No undo',
        style: TextStyle(
          color: AppPalette.warn,
          fontSize: 10,
          height: 1.3,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.1,
        ),
      ),
    );
  }
}

class _ModeIcon extends StatelessWidget {
  const _ModeIcon({required this.mode, required this.hovered});

  final AgentApprovalMode mode;
  final bool hovered;

  @override
  Widget build(BuildContext context) {
    // Menu content — detached from the anchor's rebuilds; watch theme itself.
    AppTheme.watch(context);
    final color = approvalColor(mode);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        // Was 6% of one shared grey for every mode, which made three of the four
        // icons interchangeable at a glance. Each mode now owns a hue, and the
        // chip carries enough of it to be seen.
        color: color.withValues(alpha: hovered ? 0.20 : 0.13),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(approvalIcon(mode), size: 16, color: color),
    );
  }
}

/// A mode's own hue — cool grey as you climb from "reads only" to "runs anything",
/// so the four rows are told apart by colour before they're read.
Color approvalColor(AgentApprovalMode mode) => switch (mode) {
  // A true cyan, not a blue-grey: on charcoal a desaturated slate just reads as
  // the same grey as the text beside it, which is what made this chip vanish
  // into "one of three grey blobs" in the first place.
  AgentApprovalMode.readOnly => AppTheme.pick(
    const Color(0xFF3A7D8C),
    const Color(0xFF4FC3D9),
  ),
  AgentApprovalMode.plan => AppTheme.pick(
    const Color(0xFF6435C9),
    const Color(0xFF9B7CF0),
  ),
  AgentApprovalMode.ask => AppPalette.accent,
  AgentApprovalMode.full => AppPalette.warn,
};

/// The name of a mode, as the user reads it in the composer.
String approvalLabel(AgentApprovalMode mode) => switch (mode) {
  AgentApprovalMode.readOnly => 'Read only',
  AgentApprovalMode.plan => 'Plan first',
  AgentApprovalMode.ask => 'Ask before acting',
  AgentApprovalMode.full => 'Full access',
};

/// What the mode actually means — no euphemisms for the one that stops asking.
String approvalDetail(AgentApprovalMode mode) => switch (mode) {
  AgentApprovalMode.readOnly =>
    'It can read your project files, but never change them or run anything.',
  AgentApprovalMode.plan =>
    'It shows you a plan first and does nothing until you approve it, then '
        'carries it out asking before each step.',
  AgentApprovalMode.ask =>
    'It shows you each command and each change to a file, and waits for a yes.',
  AgentApprovalMode.full =>
    'It runs commands and changes your files without asking. Nothing to undo.',
};

IconData approvalIcon(AgentApprovalMode mode) => switch (mode) {
  AgentApprovalMode.readOnly => Icons.visibility_outlined,
  AgentApprovalMode.plan => Icons.checklist_outlined,
  AgentApprovalMode.ask => Icons.pan_tool_outlined,
  AgentApprovalMode.full => Icons.bolt_outlined,
};
