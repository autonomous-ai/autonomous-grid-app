import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../shared/theme/app_theme.dart';
import '../logic/agent_permissions.dart';

/// The composer's control for how much the assistant may do to this computer.
///
/// It sits next to the model, because it's the other half of "what happens when I
/// press Send": who answers, and what they're allowed to touch. The choice sticks
/// until it's changed, and every menu line says plainly what it costs — including
/// the one that stops asking altogether.
class ApprovalPicker extends ConsumerStatefulWidget {
  const ApprovalPicker({super.key});

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

/// A menu row's corner. One radius, not the 11 that used to be typed twice in
/// the same widget for the row's shape and its decoration.
final _rowRadius = BorderRadius.circular(AppControl.radius);

class _ApprovalPickerState extends ConsumerState<ApprovalPicker> {
  final _menu = MenuController();

  void _select(AgentApprovalMode mode) {
    ref.read(chatPrefsProvider.notifier).setApproval(mode);
    _menu.close();
  }

  void _toggleMenu(BuildContext context, MenuController controller) {
    if (controller.isOpen) {
      controller.close();
      return;
    }
    controller.open();
  }

  @override
  Widget build(BuildContext context) {
    // The anchor's MenuStyle reads a token (cardBg); follow theme flips.
    AppTheme.watch(context);
    final current = ref.watch(agentApprovalModeProvider);
    return MenuAnchor(
      controller: _menu,
      // Hang the menu off the pill's top edge and let MenuAnchor measure it.
      // Passing a hand-computed position meant declaring a height before the
      // menu existed, and the rows are detail-text tall — they wrap differently
      // per row, per theme and per window width, so every guess was wrong: too
      // short dropped the menu onto the pill, too tall floated it far above.
      alignmentOffset: const Offset(0, -8),
      style: MenuStyle(
        alignment: Alignment.topLeft,
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 6),
        ),
        backgroundColor: WidgetStatePropertyAll(AppPalette.cardBg),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(8),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
      builder: (context, controller, _) => _Trigger(
        mode: current,
        onTap: () => _toggleMenu(context, controller),
      ),
    );
  }
}

/// The pill in the composer: the mode in force, and a caret.
class _Trigger extends StatelessWidget {
  const _Trigger({required this.mode, required this.onTap});

  final AgentApprovalMode mode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads color tokens; follow theme flips.
    final color = approvalColor(mode);
    final radius = BorderRadius.circular(AppControl.radius);
    return Tooltip(
      message: approvalDetail(mode),
      child: Material(
        // Neutral, like every other control in the composer. Tinting the fill and
        // the rim as well as the icon made this the loudest thing on screen on
        // the one mode that is orange — a warning parked next to the text box you
        // type in, permanently. The icon alone carries the mode; the pill itself
        // has no reason to shout, least of all forever.
        color: AppGlass.surfaceFill,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          // macOS answers a click instantly; the app's global InkRipple spreads
          // an Android-style circle across the pill instead. Hover carries it.
          splashFactory: NoSplash.splashFactory,
          hoverColor: AppGlass.surfaceHoverFill,
          child: Container(
            height: AppControl.heightSmall,
            padding: const EdgeInsets.only(left: 8, right: 7),
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: AppGlass.hair),
              boxShadow: AppGlass.cardShadow,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(approvalIcon(mode), size: 13, color: color),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    approvalLabel(mode),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      // Ink, not the accent: a whole label in the mode's colour
                      // fights the icon for the same job and turns the pill into
                      // a badge. The chip is the signal; the word is the caption.
                      color: AppPalette.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.expand_more_rounded,
                  size: 14,
                  color: AppPalette.textFaint,
                ),
              ],
            ),
          ),
        ),
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
      padding: const EdgeInsets.fromLTRB(_rowGutter + _rowInnerPad, 8, 14, 9),
      child: Text(
        'What may the assistant do on this computer?',
        style: TextStyle(
          color: AppPalette.textFaint,
          fontSize: 11.5,
          fontWeight: AppFont.medium,
        ),
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
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              height: 1.16,
                            ),
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
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppPalette.textSecondary,
                        height: 1.28,
                      ),
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
