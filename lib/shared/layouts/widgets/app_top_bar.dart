import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../../features/network/logic/grid_overview_provider.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../features/auth/logic/session_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/anchored_menu_position.dart';
import '../../widgets/status_dot.dart';
import '../shell_state.dart';
import 'hosting_summary.dart';

/// The slim strip above the open section: which grid you're working in, and
/// what's live on it (how many computers are hosting, how many models they
/// serve). Doubles as the window's drag handle on the right of the window.
///
/// Deliberately quiet — the account and the navigation live in the sidebar, so
/// nothing competes with the conversation below.
class AppTopBar extends ConsumerWidget {
  const AppTopBar({super.key});

  static const double height = 46;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final grid = ref.watch(selectedNetworkProvider);

    return DragToMoveArea(
      child: SizedBox(
        height: height,
        // Seamless with the content, like Codex — no fill, no border, no blur.
        // The pills simply float on the pane; the bar is just their row and the
        // window's drag handle.
        child: Padding(
          padding: const EdgeInsets.only(left: 16, right: 18),
          child: Row(
            children: [
              const Spacer(),
              const _StatusPill(child: HostingSummary()),
              if (grid != null) ...[
                const SizedBox(width: 8),
                _CurrentGridMenu(grid: grid),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppGlass.surfaceFill,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppGlass.hair),
        boxShadow: AppGlass.cardShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: child,
      ),
    );
  }
}

class _CurrentGridMenu extends ConsumerStatefulWidget {
  const _CurrentGridMenu({required this.grid});

  final NetworkCredential grid;

  @override
  ConsumerState<_CurrentGridMenu> createState() => _CurrentGridMenuState();
}

class _CurrentGridMenuState extends ConsumerState<_CurrentGridMenu> {
  static const _menuWidth = 270.0;

  final _menu = MenuController();

  void _toggleMenu(
    BuildContext context,
    MenuController controller,
    int gridCount,
  ) {
    if (controller.isOpen) {
      controller.close();
      return;
    }
    final height = (58 + gridCount * 48 + 54).clamp(148, 330).toDouble();
    controller.open(
      position: anchoredMenuPosition(
        context,
        menuSize: Size(_menuWidth, height),
        alignEnd: true,
        preferAbove: false,
      ),
    );
  }

  void _selectGrid(NetworkCredential grid) {
    ref.read(selectedNetworkProvider.notifier).select(grid);
    _menu.close();
  }

  void _openGrids() {
    ref.read(shellSectionProvider.notifier).select(ShellSection.grids);
    _menu.close();
  }

  @override
  Widget build(BuildContext context) {
    final grids = ref.watch(sessionProvider).networks;
    return MenuAnchor(
      controller: _menu,
      style: MenuStyle(
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 6),
        ),
        backgroundColor: WidgetStatePropertyAll(AppPalette.cardBg),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(8),
        minimumSize: const WidgetStatePropertyAll(Size(_menuWidth, 0)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      menuChildren: [
        _GridMenuContent(
          grids: grids,
          selectedId: widget.grid.networkId,
          onSelect: _selectGrid,
          onManage: _openGrids,
        ),
      ],
      builder: (context, controller, _) => Tooltip(
        message: 'Switch grid',
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () => _toggleMenu(context, controller, grids.length),
          child: _StatusPill(child: _CurrentGridLabel(grid: widget.grid)),
        ),
      ),
    );
  }
}

class _GridMenuContent extends StatelessWidget {
  const _GridMenuContent({
    required this.grids,
    required this.selectedId,
    required this.onSelect,
    required this.onManage,
  });

  final List<NetworkCredential> grids;
  final String selectedId;
  final ValueChanged<NetworkCredential> onSelect;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _CurrentGridMenuState._menuWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _GridMenuHeading(),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 250),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final grid in grids)
                    _GridMenuRow(
                      grid: grid,
                      selected: grid.networkId == selectedId,
                      onTap: () => onSelect(grid),
                    ),
                ],
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 5),
            child: Divider(height: 1),
          ),
          MenuItemButton(
            onPressed: onManage,
            style: ButtonStyle(
              padding: const WidgetStatePropertyAll(EdgeInsets.zero),
              overlayColor: WidgetStatePropertyAll(AppSurface.hoverFill),
              minimumSize: const WidgetStatePropertyAll(
                Size(_CurrentGridMenuState._menuWidth, 42),
              ),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Icon(
                    Icons.settings_outlined,
                    size: 17,
                    color: AppPalette.textSecondary,
                  ),
                  SizedBox(width: 10),
                  Text(
                    'Manage grids',
                    style: TextStyle(
                      color: AppPalette.textPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GridMenuHeading extends StatelessWidget {
  const _GridMenuHeading();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 8, 14, 7),
      child: Text(
        'Switch grid',
        style: TextStyle(
          color: AppPalette.textFaint,
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _GridMenuRow extends ConsumerWidget {
  const _GridMenuRow({
    required this.grid,
    required this.selected,
    required this.onTap,
  });

  final NetworkCredential grid;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref
        .watch(gridOverviewForProvider(grid.networkId))
        .asData
        ?.value;
    final state = overview?.state;
    final running = state?.toLowerCase() == 'running';
    final onlineNodes = overview?.nodes.where((node) => node.online).length;
    final nodes = onlineNodes == null || onlineNodes == 0
        ? overview?.stats.nodes
        : onlineNodes;
    final models = overview == null || overview.models.isEmpty
        ? overview?.stats.models
        : overview.models.length;
    return MenuItemButton(
      onPressed: onTap,
      style: ButtonStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        backgroundColor: WidgetStatePropertyAll(
          selected ? const Color(0x062F5BEA) : Colors.transparent,
        ),
        overlayColor: WidgetStatePropertyAll(AppSurface.hoverFill),
        minimumSize: const WidgetStatePropertyAll(
          Size(_CurrentGridMenuState._menuWidth, 48),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 7, 12, 7),
        child: Row(
          children: [
            StatusDot(
              color: running ? AppPalette.online : AppPalette.offline,
              size: 8,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    grid.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppPalette.textPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    _gridMeta(grid, nodes: nodes, models: models),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppPalette.textFaint,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.check_rounded,
              size: 17,
              color: selected ? AppPalette.accent : Colors.transparent,
            ),
          ],
        ),
      ),
    );
  }

  String _gridMeta(NetworkCredential grid, {int? nodes, int? models}) {
    final pieces = <String>[grid.roleLabel, grid.visibilityLabel];
    if (nodes != null) pieces.add(nodes == 1 ? '1 node' : '$nodes nodes');
    if (models != null) {
      pieces.add(models == 1 ? '1 model' : '$models models');
    }
    return pieces.join(' · ');
  }
}

/// The active grid — a live Running / Stopped dot, a faint "Grid ·" caption, then
/// the name. No box: it reads as a label, so you always know which grid answers
/// your messages without it competing with the window chrome.
class _CurrentGridLabel extends ConsumerWidget {
  const _CurrentGridLabel({required this.grid});

  final NetworkCredential grid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final state = ref
        .watch(gridOverviewForProvider(grid.networkId))
        .asData
        ?.value
        .state;
    final running = state?.toLowerCase() == 'running';
    return ConstrainedBox(
      // Cap the width and ellipsize so a long grid name can't overflow the bar.
      constraints: const BoxConstraints(maxWidth: 280),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(
            color: running ? AppPalette.online : AppPalette.offline,
            size: 8,
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'Grid · ',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AppPalette.textSecondary,
                    ),
                  ),
                  TextSpan(
                    text: grid.name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: AppPalette.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
