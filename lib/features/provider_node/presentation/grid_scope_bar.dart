import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../auth/logic/session_controller.dart';
import '../logic/grid_choices.dart';
import 'grid_monogram.dart';
import 'grid_switch_chips.dart';

/// Which grid everything below applies to — and, when the account has more than
/// one, every other grid as a chip that switches to it.
///
/// **The switcher is on the surface, not behind a button.** It used to be a
/// "Switch" trigger opening a menu, which hid the one fact this bar exists to
/// settle: which grid, *out of which others*. An account with three grids read
/// as an account with one, and finding the second one was a click into a menu
/// nothing on the page suggested was worth opening. Chips cost a line of the
/// card and answer it at a glance.
///
/// Deliberately a strip, not a card of its own: it frames the page rather than
/// competing with the cards below, which carry the actual state and controls.
class GridScopeBar extends ConsumerWidget {
  const GridScopeBar({super.key, required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final grids = ref.watch(sessionProvider).networks;
    final others = buildGridChoices(grids, network);

    return Container(
      padding: const EdgeInsets.fromLTRB(13, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppCard.base,
        borderRadius: BorderRadius.circular(AppCard.radius),
        border: Border.all(color: AppCard.hair),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _CurrentGrid(network: network),
          if (!others.isEmpty) ...[
            const SizedBox(height: 11),
            // The theme's hairline is the card's own rim colour, so no token is
            // restated here.
            const Divider(height: 1),
            const SizedBox(height: 10),
            GridSwitchChips(choices: others),
          ],
        ],
      ),
    );
  }
}

/// The grid this page is about: its name, the viewer's standing on it, and the
/// role badge.
class _CurrentGrid extends StatelessWidget {
  const _CurrentGrid({required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        GridMonogram(name: network.name),
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
      ],
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
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}
