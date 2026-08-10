import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/chat_drop.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_icon_button.dart';
import '../logic/panel_layout.dart';
import '../logic/panel_tabs.dart';
import '../logic/preview_panel.dart';
import 'panel_feature_menu.dart';

/// A panel's header: one tab per thing open in it, plus the way to open
/// another.
///
/// Shared by every feature *and* by both panels — the strip is the panel's own
/// chrome, so switching tabs never moves it, and the panel under the chat works
/// the way the one beside it does rather than being a lookalike with its own
/// habits.
///
/// Tabs share the width they have: they shrink as more open, down to a floor,
/// and only past that floor does the row start scrolling. A strip that never
/// shrank pushed the fourth tab — and the "+" — out of sight in a panel this
/// narrow, and a strip that shrank without a floor would end in stubs too short
/// to read.
///
/// The "+" sits outside that entirely, pinned to the trailing edge: it is how
/// you open the next thing, so it is the one control that must never be the
/// thing that scrolled away. Expand sits just inside it, so "+" keeps the corner
/// it has always had.
class PanelTabStrip extends ConsumerWidget {
  const PanelTabStrip({
    super.key,
    required this.host,
    this.onRaisedSurface = false,
  });

  /// Which panel's tabs this is showing.
  final PanelHost host;

  /// Set when the panel is floating over the chat instead of docked beside it —
  /// the selected tab's fill is tuned against the page and matches the raised
  /// surface exactly, so it needs the raised variant. See [AppGlass.bubbleFill].
  final bool onRaisedSurface;

  static const double height = 38;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final state = ref.watch(panelTabsProvider(host));
    final controller = ref.read(panelTabsProvider(host).notifier);

    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final count = state.tabs.length;
                  final width = tabStripTabWidth(
                    available: constraints.maxWidth,
                    count: count,
                  );
                  final row = Row(
                    children: [
                      for (final tab in state.tabs) ...[
                        // A ceiling, not a width: a chip whose fill runs on past
                        // its label reads as a text field, not a tab. Short
                        // labels take what they need; long ones stop here and
                        // ellipsis, which is what keeps the row inside the strip.
                        ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: width),
                          child: _Tab(
                            tab: tab,
                            selected: tab.id == state.activeId,
                            onRaisedSurface: onRaisedSurface,
                            onSelect: () => controller.select(tab.id),
                            onClose: () => controller.close(tab.id),
                          ),
                        ),
                        const SizedBox(width: kTabGap),
                      ],
                    ],
                  );
                  // Only once they are already as narrow as they may go.
                  return tabStripScrolls(
                        available: constraints.maxWidth,
                        count: count,
                      )
                      ? SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: row,
                        )
                      : row;
                },
              ),
            ),
            if (host == PanelHost.preview) const _ExpandButton(),
            PanelFeatureMenu(onSelected: controller.open),
          ],
        ),
      ),
    );
  }
}

/// Hands this panel the whole pane, and gives the conversation back.
///
/// Only in the panel beside the chat. Expanding is "take the room the chat is
/// using", and the panel *under* the chat has no chat beside it to take room
/// from — a button there would need a different meaning, which is a different
/// button.
///
/// Quiet rather than lit-when-active, unlike the top bar's toggles: the icon
/// already flips, and a permanently accent-coloured glyph beside a neutral "+"
/// reads as something being wrong rather than as a state.
class _ExpandButton extends ConsumerWidget {
  const _ExpandButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final expanded = ref.watch(previewPanelExpandedProvider);
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: AppIconButton(
        icon: expanded ? LucideIcons.minimize2 : LucideIcons.maximize2,
        size: 15,
        // Not "Show/Hide": nothing appears or goes away, the panel changes size.
        tooltip: expanded ? 'Restore panel' : 'Expand panel',
        onPressed: () =>
            ref.read(previewPanelExpandedProvider.notifier).toggle(),
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

  /// Whether this build is the one where the selection moved.
  ///
  /// Selection is drawn *instantly*; only hover is animated. Fading it looked
  /// like both tabs lighting up at once and then one giving in: for 130ms the
  /// tab being left still carried its fill and shadow while the tab arriving
  /// already had them, which reads as a flash across the whole strip rather
  /// than as a switch. A click is a decision, and a decision the app has
  /// already acted on has nothing left to animate.
  bool _switching = false;

  @override
  void didUpdateWidget(_Tab oldWidget) {
    super.didUpdateWidget(oldWidget);
    _switching = oldWidget.selected != widget.selected;
  }

  /// The pointer arriving or leaving — which *is* worth easing, and which must
  /// not inherit the instant duration a switch just asked for.
  void _hover(bool value) => setState(() {
    _hovered = value;
    _switching = false;
  });

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final motion = _switching ? Duration.zero : AppMotion.hover;
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

    final chip = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _hover(true),
      onExit: (_) => _hover(false),
      child: GestureDetector(
        onTap: widget.onSelect,
        child: AnimatedContainer(
          duration: motion,
          curve: AppMotion.curve,
          height: 26,
          // No width of its own: the strip hands every tab the same width, so
          // one tab widening as the row shrinks would be a tab out of step.
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
            // Hugs its label: the strip caps how wide a tab may get, and the
            // tab takes only what it needs of that.
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
                duration: motion,
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

    // Only a terminal, and only by its tab. A terminal is the one surface here
    // whose worth to a message is the whole screen rather than a line picked out
    // of it, so the tab — the handle for "this terminal" — is what you drag.
    // Review and Files hand over a file or a quote instead, and both already
    // have their own way to do it.
    if (widget.tab.feature != PanelFeature.terminal) return chip;
    return Draggable<ChatDrop>(
      data: TerminalDrop(tabId: widget.tab.id, label: widget.tab.title),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _DragChip(label: widget.tab.title),
      // The tab stays put, dimmed: it is a handle, not the thing itself, and a
      // tab strip that reflows mid-drag moves the other tabs under the pointer.
      childWhenDragging: Opacity(opacity: 0.4, child: chip),
      child: chip,
    );
  }
}

/// A terminal tab in flight — the same shape the file tree's drag uses, so the
/// two gestures answer alike.
class _DragChip extends StatelessWidget {
  const _DragChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 260),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppGlass.surfaceFill,
            borderRadius: BorderRadius.circular(8),
            boxShadow: AppGlass.cardShadow,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.squareTerminal,
                  size: 13,
                  color: AppPalette.textSecondary,
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppPalette.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
