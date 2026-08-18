import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../auth/logic/session_controller.dart';
import '../logic/grid_choices.dart';
import 'grid_monogram.dart';

/// The other grids the account belongs to, one chip each.
///
/// Switching is pure app state
/// ([SelectedNetwork.select] never rewrites `~/.grid`, the CLI owns that), so a
/// click here is as cheap and reversible as it looks.
class GridSwitchChips extends StatelessWidget {
  const GridSwitchChips({super.key, required this.choices});

  final GridChoices choices;

  @override
  Widget build(BuildContext context) {
    if (choices.isSplit) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _GridGroup(label: 'You can share here', grids: choices.canShare),
          const SizedBox(height: 11),
          _GridGroup(label: 'View only', grids: choices.viewOnly, muted: true),
        ],
      );
    }
    // One group needs no heading telling it from another, so the heading says
    // what clicking does instead — except when nothing in it can be served on,
    // where the limitation is the more useful thing to say. Never both words:
    // "Switch to" over grids you can't share on would read as an invitation to
    // do the very thing this page is for.
    final viewOnly = choices.canShare.isEmpty;
    return _GridGroup(
      label: viewOnly ? 'View only' : 'Switch to',
      grids: viewOnly ? choices.viewOnly : choices.canShare,
      muted: viewOnly,
    );
  }
}

/// One labelled run of grid chips.
class _GridGroup extends StatelessWidget {
  const _GridGroup({
    required this.label,
    required this.grids,
    this.muted = false,
  });

  final String label;
  final List<NetworkCredential> grids;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 10.5 / w700 / 0.6 tracking — the group-heading type the chat model
        // picker uses, so every list of things to pick reads as one system.
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: AppPalette.textSecondary,
          ),
        ),
        const SizedBox(height: 7),
        // Wraps rather than scrolls sideways: an account with a dozen grids
        // grows this strip by a line instead of hiding grids off the right
        // edge, and the page it heads scrolls anyway.
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final grid in grids) _GridChip(grid: grid, muted: muted),
          ],
        ),
      ],
    );
  }
}

/// One grid, one click away.
class _GridChip extends ConsumerWidget {
  const _GridChip({required this.grid, required this.muted});

  final NetworkCredential grid;

  /// Quieter styling for a grid no model can be shared on.
  final bool muted;

  /// Long grid names ellipsise rather than stretching a chip across the card.
  static const double _maxNameWidth = 170;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final radius = BorderRadius.circular(AppControl.radius);
    return Tooltip(
      message: muted
          ? "Switch to ${grid.name} — you can't share a model there"
          : 'Switch to ${grid.name}',
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
              color: AppCard.inset,
              borderRadius: radius,
              border: Border.all(color: AppCard.insetHair),
            ),
            padding: const EdgeInsets.fromLTRB(6, 5, 10, 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                GridMonogram(name: grid.name, size: 18, muted: muted),
                const SizedBox(width: 7),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: _maxNameWidth),
                  child: Text(
                    grid.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppControl.fontSize,
                      height: 1.2,
                      color: muted
                          ? AppPalette.textSecondary
                          : AppPalette.textPrimary,
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
