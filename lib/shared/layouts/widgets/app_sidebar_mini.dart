import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:window_manager/window_manager.dart';

import '../../../features/chat/logic/chat_sessions_controller.dart';
import '../../../features/command_palette/presentation/command_palette.dart';
import '../../../features/provider_node/logic/serving_engines_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/status_dot.dart';
import '../shell_state.dart';
import 'sidebar_account.dart';

/// The sidebar folded down to its glyphs — the collapsed half of `AppSidebar`.
///
/// Collapsing narrows the rail, it does not remove it: navigation is the one
/// thing that has to stay reachable from every screen, and a rail that vanishes
/// leaves the app with no way in or out except a single button borrowed by the
/// top bar. What is dropped is only what needs words — the chat list, the
/// project tree — because a title at 72px is an ellipsis. Everything kept is a
/// glyph that names itself in a tooltip, and ⌘K still finds a conversation.
class AppSidebarMini extends ConsumerWidget {
  const AppSidebarMini({super.key});

  /// Wide enough that the macOS traffic lights land *inside* the rail rather
  /// than straddling its right edge — they float over the window because the
  /// title bar is hidden (see `main.dart`) and reach roughly 70px in, so a
  /// narrower rail would spill the last button onto the pane and split one
  /// control across two surfaces. It also leaves the tiles a 16px gutter, which
  /// is what keeps a column of icons reading as a rail rather than a stack.
  static const double width = 72;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Const-mounted, like the wide rail — so this is where the subscription has
    // to be, or the `const` children below keep the palette they first mounted
    // with. (The fill and the hairline are `SidebarFold`'s, not this rail's.)
    AppTheme.watch(context);
    final mode = ref.watch(shellModeProvider);

    return ClipRect(
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _MiniHead(
              onExpand: () =>
                  ref.read(sidebarCollapsedProvider.notifier).toggle(),
              onSearch: () => showCommandPalette(context),
            ),
            // Carries its own hairline, and both go together in a build with
            // one half to offer — see [_MiniModeSwitch].
            const _MiniModeSwitch(),
            // Scrollable: on a short window four tiles plus the account still
            // have to fit, and a rail that overflows is a red-striped box.
            Expanded(
              child: SingleChildScrollView(
                child: switch (mode) {
                  ShellMode.home => _MiniHomeRail(
                    onNewChat: () {
                      ref.read(chatSessionsProvider.notifier).newChat();
                      ref
                          .read(shellSectionProvider.notifier)
                          .select(ShellSection.chat);
                    },
                  ),
                  // Code's rail is projects and their runs — rows that are
                  // nothing but names. Folded, the half keeps its switch and
                  // its pane, and the names come back with the rail.
                  ShellMode.code => const SizedBox.shrink(),
                },
              ),
            ),
            const Divider(height: 1, thickness: 1),
            const SizedBox(height: 4),
            const SidebarAccount(compact: true),
          ],
        ),
      ),
    );
  }
}

/// The rail's head: the way back to the full sidebar, and ⌘K.
///
/// Carries the same top inset as the wide rail's wordmark, for the same reason —
/// the macOS traffic lights float over whatever is drawn at the top of the
/// window, so the first tile starts below them. Doubles as the window's drag
/// handle up here, where the wordmark would be.
class _MiniHead extends StatelessWidget {
  const _MiniHead({required this.onExpand, required this.onSearch});

  final VoidCallback onExpand;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final topInset = Platform.isMacOS ? 32.0 : 12.0;
    return DragToMoveArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(0, topInset, 0, 6),
        child: Column(
          children: [
            MiniRailItem(
              icon: LucideIcons.panelLeft300,
              tooltip: 'Expand sidebar  ⌘\\',
              onTap: onExpand,
            ),
            MiniRailItem(
              icon: LucideIcons.search300,
              tooltip: 'Search everything  ⌘K',
              onTap: onSearch,
            ),
          ],
        ),
      ),
    );
  }
}

/// One tile per half of the app — the folded form of the wide rail's segmented
/// control.
///
/// It survives the fold because it is the only control that changes what every
/// tile under it means: a user who collapsed the rail while in Code has to be
/// able to get back without expanding first.
///
/// Drawn from [visibleShellModes], and gone entirely when this build offers
/// only one half — same rule as the segmented control it folds from, and it
/// takes the hairline under it along, so a release build doesn't open the rail
/// with a rule over nothing.
class _MiniModeSwitch extends ConsumerWidget {
  const _MiniModeSwitch();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modes = visibleShellModes;
    if (modes.length < 2) return const SizedBox.shrink();
    final mode = ref.watch(shellModeProvider);
    return Column(
      children: [
        for (final half in modes)
          MiniRailItem(
            // The mode's own glyph and word, so a half that is hidden takes
            // both with it rather than leaving a copy typed in here.
            icon: half.icon,
            tooltip: half.label,
            selected: mode == half,
            onTap: () => ref.read(shellModeProvider.notifier).select(half),
          ),
        const _MiniDivider(),
      ],
    );
  }
}

/// The everyday tiles: start a chat, get back to the one you're in, and the
/// screens the wide rail lists beside it.
class _MiniHomeRail extends ConsumerWidget {
  const _MiniHomeRail({required this.onNewChat});

  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final section = ref.watch(shellSectionProvider);
    final serving = ref.watch(servingEnginesProvider).isNotEmpty;
    return Column(
      children: [
        MiniRailItem(
          icon: LucideIcons.squarePen300,
          tooltip: 'New chat',
          emphasized: true,
          onTap: onNewChat,
        ),
        // Chat earns a tile here that it doesn't have in the wide rail: there,
        // the way back to the conversation is to click it in the list below —
        // and the list is exactly what folding drops.
        MiniRailItem(
          icon: ShellSection.chat.thinIcon,
          tooltip: ShellSection.chat.label,
          selected: section == ShellSection.chat,
          onTap: () =>
              ref.read(shellSectionProvider.notifier).select(ShellSection.chat),
        ),
        for (final target in kSidebarSections)
          MiniRailItem(
            icon: target.thinIcon,
            tooltip: target.label,
            selected: section == target,
            // The one mark that survives the fold, and the same condition the
            // wide rail uses: this machine serving is the only state that
            // changes while the user is somewhere else.
            badge: serving && target == ShellSection.engines
                ? const _ServingDot()
                : null,
            onTap: () => ref.read(shellSectionProvider.notifier).select(target),
          ),
      ],
    );
  }
}

/// The live mark on the Model engines tile while this computer is serving.
///
/// Folded, it can't sit after a label, so it rides the tile's top-right corner —
/// the one place on a 40px square that no glyph reaches.
class _ServingDot extends StatelessWidget {
  const _ServingDot();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return StatusDot(color: AppPalette.online, size: 6);
  }
}

/// A hairline between the mode switch and the screens under it.
///
/// Inset from the rail's edges so it separates the two runs without reading as a
/// border across the whole column — the same trick the compact settings nav
/// plays where its group captions won't fit.
class _MiniDivider extends StatelessWidget {
  const _MiniDivider();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 18, vertical: 6),
    child: Divider(height: 1),
  );
}

/// One tile in the folded rail: a glyph, its name in a tooltip, and the same
/// hover/selected language a `SidebarItem` speaks.
///
/// Square rather than a full-width band, and centred in the rail: at this width
/// a band would be a 72px block of fill around an 18px glyph, which reads as a
/// button that failed to lay out. The states are the row's, unchanged — the
/// selected tile takes [AppSurface.selectedFill] and the accent glyph, the
/// primary action keeps its accent wash, everything else climbs from
/// [AppPalette.textSecondary] to [AppPalette.textPrimary] under the pointer.
class MiniRailItem extends StatefulWidget {
  const MiniRailItem({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.selected = false,
    this.emphasized = false,
    this.badge,
  });

  final IconData icon;

  /// The name the label would have carried. Not optional: a glyph with no
  /// tooltip in a rail with no labels is a control the user has to click to
  /// identify.
  final String tooltip;

  final VoidCallback onTap;
  final bool selected;

  /// The rail's primary action ("New chat") — accent wash at rest, the way the
  /// wide rail draws it.
  final bool emphasized;

  /// A small always-visible mark in the tile's top-right corner.
  final Widget? badge;

  /// The tile's box. 40 rather than the wide row's 36: a square target is
  /// smaller to hit than a band, and this one is the only way to reach the
  /// screen behind it.
  static const double box = 40;

  @override
  State<MiniRailItem> createState() => _MiniRailItemState();
}

class _MiniRailItemState extends State<MiniRailItem> {
  bool _hovered = false;

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);

    final fill = switch ((widget.selected, widget.emphasized)) {
      (true, _) => AppSurface.selectedFill,
      (_, true) =>
        _hovered ? AppSurface.accentWashHover : AppSurface.accentWash,
      _ => _hovered ? AppSurface.hoverFill : Colors.transparent,
    };
    // Same ramp as the wide row's icon: the accent means "this is the one" (or
    // "this is the action"), and nothing else reaches it.
    final ink = widget.selected || widget.emphasized
        ? AppPalette.accentOnSurface
        : (_hovered ? AppPalette.textPrimary : AppPalette.textSecondary);

    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.tooltip,
      child: Tooltip(
        message: widget.tooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => _setHovered(true),
          onExit: (_) => _setHovered(false),
          child: GestureDetector(
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              // Centres the tile in the rail while leaving the rest of the row
              // dead space — hover belongs to the square, not to the column.
              child: Center(
                child: AnimatedContainer(
                  duration: AppMotion.hover,
                  curve: AppMotion.curve,
                  width: MiniRailItem.box,
                  height: MiniRailItem.box,
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: BorderRadius.circular(AppControl.radius),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Icon(widget.icon, size: 18, color: ink),
                      if (widget.badge != null)
                        Positioned(top: 7, right: 7, child: widget.badge!),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
