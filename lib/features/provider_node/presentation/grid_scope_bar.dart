import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/anchored_menu_position.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../auth/logic/session_controller.dart';

/// Which grid everything below applies to, and a way to change it.
///
/// The Engines tab talks about "this grid" throughout — what you may do on it,
/// what this computer serves to it — but the Settings pane has no top bar
/// (`SettingsPane` doesn't mount `AppTopBar`), so nothing on screen named the
/// grid those sentences meant. Readers had to infer it from a subordinate
/// clause. This is the anchor: the grid's name, the viewer's standing on it, and
/// a switcher.
///
/// Deliberately a strip, not a card: it frames the page rather than competing
/// with the cards below, which carry the actual state and controls.
class GridScopeBar extends ConsumerWidget {
  const GridScopeBar({super.key, required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final grids = ref.watch(sessionProvider).networks;

    return Container(
      padding: const EdgeInsets.fromLTRB(13, 10, 10, 10),
      decoration: BoxDecoration(
        color: AppCard.base,
        borderRadius: BorderRadius.circular(AppCard.radius),
        border: Border.all(color: AppCard.hair),
      ),
      child: Row(
        children: [
          _GridMonogram(name: network.name),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  network.name,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _standing(network),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _RoleChip(network: network),
          // One grid means nothing to switch to — a menu that can only pick what
          // is already picked is noise.
          if (grids.length > 1) ...[
            const SizedBox(width: 6),
            _GridSwitcher(current: network, grids: grids),
          ],
        ],
      ),
    );
  }

  /// The viewer's relationship to this grid, in the product's words. Ownership
  /// is the fact that decides whether anything here is even negotiable, so it
  /// leads; visibility follows as context.
  static String _standing(NetworkCredential network) {
    final owner = network.isOwner
        ? 'You own this grid'
        : 'Owned by someone else';
    return '$owner · ${network.visibilityLabel}';
  }
}

/// The grid's initial in a tinted tile — a fast visual anchor when switching
/// between grids, so the eye catches "wrong grid" before reading the name.
class _GridMonogram extends StatelessWidget {
  const _GridMonogram({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final trimmed = name.trim();
    final initial = trimmed.isEmpty ? '?' : trimmed.characters.first;
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppPalette.accentOnSurface.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        initial.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: AppPalette.accentOnSurface,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// The viewer's role on this grid (Owner / Sharing / Using / Member), from the
/// token's own claim — the same word the web console shows, so the two agree.
class _RoleChip extends StatelessWidget {
  const _RoleChip({required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    // Owner is the one role that grants control here, so it wears the teal the
    // rest of the app uses for that badge; every other role stays neutral —
    // "Using" is not a lesser state, just a different one.
    final owner = network.isOwner;
    final color = owner ? AppPalette.teal : theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: owner ? color.withValues(alpha: 0.12) : AppCard.inset,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: owner ? color.withValues(alpha: 0.28) : AppCard.insetHair,
        ),
      ),
      child: Text(
        network.roleLabel,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Switch which grid this tab is about. Pure app state — [SelectedNetwork.select]
/// never rewrites `~/.grid`, the CLI owns that — so switching here is as cheap
/// and reversible as it looks.
class _GridSwitcher extends ConsumerWidget {
  const _GridSwitcher({required this.current, required this.grids});

  final NetworkCredential current;
  final List<NetworkCredential> grids;

  /// A two-line row (name over role). Only used to place the menu, not to size
  /// it — [MenuAnchor] still measures the real thing, so an estimate that's a
  /// little off shifts the menu, it doesn't clip it.
  static const _rowHeight = 46.0;

  /// A one-line row — the common case now that a role repeating its group
  /// heading is dropped (see [_roleAddsInfo]). Counting every row at
  /// [_rowHeight] would over-estimate a 7-grid menu by ~100px and push it well
  /// off its anchor.
  static const _rowHeightSingle = 31.0;

  static const _menuWidth = 240.0;

  /// A group heading plus the gap above it — counted into the height estimate so
  /// a sectioned menu still lands where it's told.
  static const _labelHeight = 30.0;

  /// Whether the list splits into two labelled groups (see [_sectioned]).
  bool get _isSectioned =>
      grids.any((g) => g.isProvider) && grids.any((g) => !g.isProvider);

  void _toggle(BuildContext context, MenuController controller) {
    if (controller.isOpen) {
      controller.close();
      return;
    }
    // The trigger sits at the bar's trailing edge, hard against the window. A
    // menu grown rightwards from it runs off-screen and the longest grid names
    // get clipped — which is exactly what happened before this. Right-align it
    // and let the helper clamp it inside the overlay.
    // Measured per row, since most rows are now a single line. Uses the same
    // _roleAddsInfo test the rows themselves use, so the estimate can't drift
    // from what actually gets built.
    final sectioned = _isSectioned;
    var height = 16.0 + (sectioned ? _labelHeight * 2 + 4 : 0);
    for (final grid in grids) {
      height += _roleAddsInfo(grid, grouped: sectioned)
          ? _rowHeight
          : _rowHeightSingle;
    }
    controller.open(
      position: anchoredMenuPosition(
        context,
        menuSize: Size(_menuWidth, height),
        margin: 8,
        gap: 6,
        alignEnd: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return MenuAnchor(
      // The shared floating-menu surface, so this and the model menu read as one
      // control. No `alignment` here: _toggle passes an explicit position, and
      // an alignment would fight it.
      style: appMenuStyle(),
      builder: (context, controller, _) => Tooltip(
        message: 'Switch grid',
        child: TextButton.icon(
          onPressed: () => _toggle(context, controller),
          icon: const Icon(Icons.unfold_more, size: 16),
          label: const Text('Switch'),
          style: TextButton.styleFrom(
            foregroundColor: theme.colorScheme.onSurfaceVariant,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ),
      menuChildren: _sectioned(ref, theme),
    );
  }

  /// The grid list split by the one thing this tab is about: whether you can
  /// share a model on it.
  ///
  /// Grouping by *ownership* would be the obvious read of "Owner / the rest",
  /// but it's the wrong axis here — sharing is gated on the `provider:poll`
  /// scope ([NetworkCredential.isProvider]), not on the admin role, and the two
  /// come apart: a grid someone else owns can grant you sharing rights, and it
  /// belongs at the top with the others you can serve on.
  ///
  /// Headings only appear when both groups exist; one group needs no label to
  /// tell it from the other. Order within a group is left as the credentials
  /// file has it, so grids don't reshuffle under the cursor between openings.
  List<Widget> _sectioned(WidgetRef ref, ThemeData theme) {
    final canShare = [
      for (final g in grids)
        if (g.isProvider) g,
    ];
    final viewOnly = [
      for (final g in grids)
        if (!g.isProvider) g,
    ];

    // Ungrouped: no heading is carrying the "can you share here?" fact, so every
    // row states its own role.
    if (canShare.isEmpty || viewOnly.isEmpty) {
      return [for (final grid in grids) _row(ref, theme, grid, grouped: false)];
    }
    return [
      _SectionLabel(text: 'You can share here'),
      for (final grid in canShare) _row(ref, theme, grid, grouped: true),
      const SizedBox(height: 4),
      _SectionLabel(text: 'View only'),
      for (final grid in viewOnly) _row(ref, theme, grid, grouped: true),
    ];
  }

  /// Whether [grid]'s role line says anything its group heading hasn't.
  ///
  /// The menu groups by [NetworkCredential.isProvider] while the role line prints
  /// [NetworkCredential.roleLabel] — two different axes that usually agree. When
  /// they do, the line is pure repetition: a "You can share here" group of three
  /// admin grids printed "Owner" three times under a heading that already said
  /// so, and "View only" printed "Using" four times.
  ///
  /// They come apart for the middle roles — `provider` ("Sharing") sits in the
  /// can-share group without owning it, and `member` ("Member") is a view-only
  /// grid that isn't merely consuming. Those are exactly the cases where the
  /// line earns its space, so it's kept only for them.
  static bool _roleAddsInfo(NetworkCredential grid, {required bool grouped}) {
    if (!grouped) return true;
    return switch (grid.role) {
      NetworkRole.admin || NetworkRole.consumer => false,
      NetworkRole.provider || NetworkRole.member => true,
    };
  }

  /// Same row construction as the select field's and the chat model picker's —
  /// `MenuItemButton` is unthemed in this app, so its M3 defaults (square
  /// corners, 14pt text, Material's grey hover, an ink ripple) would put this
  /// menu outside the design system.
  Widget _row(
    WidgetRef ref,
    ThemeData theme,
    NetworkCredential grid, {
    required bool grouped,
  }) {
    final selected = grid.networkId == current.networkId;
    final showRole = _roleAddsInfo(grid, grouped: grouped);
    final radius = BorderRadius.circular(AppControl.radius);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          onTap: () => ref.read(selectedNetworkProvider.notifier).select(grid),
          borderRadius: radius,
          hoverColor: AppSurface.hoverFill,
          splashFactory: NoSplash.splashFactory,
          child: Ink(
            decoration: BoxDecoration(
              color: selected ? AppSurface.accentWash : Colors.transparent,
              borderRadius: radius,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
            child: SizedBox(
              // A fixed width so the menu doesn't resize itself around whichever
              // grid happens to have the longest name, and so a very long one
              // ellipsises instead of stretching the panel off-screen.
              width: _menuWidth - 30,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 16,
                    child: selected
                        ? Icon(
                            Icons.check_rounded,
                            size: AppControl.iconSize,
                            color: AppPalette.accentMuted,
                          )
                        : null,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Weight marks the current grid as well as the tick —
                        // one glance tells you where you are.
                        Text(
                          grid.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppControl.fontSize,
                            height: 1.2,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: AppPalette.textPrimary,
                          ),
                        ),
                        // Only when it says something the group heading didn't —
                        // see _roleAddsInfo.
                        if (showRole) ...[
                          const SizedBox(height: 3),
                          Text(
                            grid.roleLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.28,
                              color: AppPalette.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
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

/// A group heading inside the switcher menu. Not a [MenuItemButton]: it must not
/// take focus or respond to arrow keys, or keyboard users would land on a label
/// that does nothing.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // 10.5 / w700 / 0.6 tracking — the group-heading type the chat model
    // picker uses, so the two menus read as one system. Indented to the rows'
    // label column (gutter 6 + inner 9) so headings and labels share an edge.
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 8, 15, 5),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: AppPalette.textSecondary,
        ),
      ),
    );
  }
}
