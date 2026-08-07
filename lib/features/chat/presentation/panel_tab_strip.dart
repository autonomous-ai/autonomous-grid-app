import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_icon_button.dart';
import '../logic/panel_tabs.dart';
import 'panel_feature_menu.dart';

/// The preview panel's header: one tab per thing open in it, plus the way to
/// open another.
///
/// Shared by every feature and fixed at the top of the panel — the tab strip is
/// the panel's own chrome, so switching tabs never moves it.
///
/// Scrolls sideways rather than shrinking its tabs: a row of tabs that squeezes
/// as you open more ends with a row of unreadable stubs.
class PanelTabStrip extends ConsumerWidget {
  const PanelTabStrip({super.key, this.onRaisedSurface = false});

  /// Set when the panel is floating over the chat instead of docked beside it —
  /// the selected tab's fill is tuned against the page and matches the raised
  /// surface exactly, so it needs the raised variant. See [AppGlass.bubbleFill].
  final bool onRaisedSurface;

  static const double height = 38;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final state = ref.watch(panelTabsProvider);
    final controller = ref.read(panelTabsProvider.notifier);

    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final tab in state.tabs) ...[
                _Tab(
                  tab: tab,
                  selected: tab.id == state.activeId,
                  onRaisedSurface: onRaisedSurface,
                  onSelect: () => controller.select(tab.id),
                  onClose: () => controller.close(tab.id),
                ),
                const SizedBox(width: 4),
              ],
              PanelFeatureMenu(onSelected: controller.open),
            ],
          ),
        ),
      ),
    );
  }
}

/// One tab.
///
/// Owns its own hover: the strip around it can't tell it where the pointer is,
/// and the close button inside it owns its hover in turn.
class _Tab extends StatefulWidget {
  const _Tab({
    required this.tab,
    required this.selected,
    required this.onRaisedSurface,
    required this.onSelect,
    required this.onClose,
  });

  final PanelTab tab;
  final bool selected;
  final bool onRaisedSurface;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // Selected reads as a raised chip; hovered as a wash under the label. Two
    // different questions, so two different treatments — a hover that borrowed
    // the selected fill would say the pointer had already switched tabs.
    final Color fill;
    if (widget.selected) {
      fill = widget.onRaisedSurface ? AppGlass.bubbleFill : AppGlass.rowFill;
    } else if (_hovered) {
      fill = AppSurface.hoverFill;
    } else {
      fill = Colors.transparent;
    }
    final ink = widget.selected || _hovered
        ? AppPalette.textPrimary
        : AppPalette.textSecondary;
    // The close button is always in the tree — pulling it out on the tabs that
    // aren't hovered would resize every tab as the pointer crossed the strip.
    final showClose = widget.selected || _hovered;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onSelect,
        child: AnimatedContainer(
          duration: AppMotion.hover,
          curve: AppMotion.curve,
          height: 26,
          constraints: const BoxConstraints(maxWidth: 180),
          padding: const EdgeInsets.only(left: 8, right: 4),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(8),
            // Fill alone doesn't lift a chip off this page — 1.05:1 in light.
            // Depth is the shadow's job, which is why the app can do without
            // borders at all.
            boxShadow: widget.selected ? AppGlass.cardShadow : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.tab.feature.icon, size: 13, color: ink),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  widget.tab.title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: AppFont.medium,
                    color: ink,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              AnimatedOpacity(
                duration: AppMotion.hover,
                curve: AppMotion.curve,
                opacity: showClose ? 1 : 0,
                child: IgnorePointer(
                  ignoring: !showClose,
                  child: AppIconButton(
                    icon: Icons.close_rounded,
                    size: 12,
                    tooltip: 'Close ${widget.tab.title}',
                    onPressed: widget.onClose,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
