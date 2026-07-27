import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/empty_state.dart';
import '../logic/model_manager_filter.dart';
import '../logic/model_shelf.dart';
import 'shelf_model_tile.dart';

/// What's on this computer: every model under `~/.grid/models`, its size, and
/// the way to delete it.
///
/// No section header. The tab is the header — the old dialog printed
/// "ON THIS COMPUTER" one row under a subtitle that already ended in "on this
/// computer", which is the same three words twice within 40px.
class InstalledTab extends StatelessWidget {
  const InstalledTab({
    super.key,
    required this.installed,
    required this.query,
    required this.onDiscover,
  });

  final List<ShelfModel> installed;

  /// The filter box on the controls strip. Listened to here rather than lifted
  /// into the parent's state so a keystroke rebuilds this list alone.
  final TextEditingController query;

  /// Switches to Discover — the action on both empty states.
  final VoidCallback onDiscover;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return ListenableBuilder(
      listenable: query,
      builder: (context, _) {
        final matches = filterInstalled(installed, query.text);

        if (installed.isEmpty) {
          return _Empty(
            icon: Icons.inbox_outlined,
            title: 'No models yet',
            message:
                'Download one to run a model on this computer, privately and '
                'offline.',
            actionLabel: 'Find a model',
            onAction: onDiscover,
          );
        }

        // A query that matches nothing is a different situation from an empty
        // shelf, and its way out is to clear the box — not to go downloading.
        if (matches.isEmpty) {
          return _Empty(
            icon: Icons.search_off_rounded,
            title: 'No match',
            message: 'No installed model matches "${query.text.trim()}".',
            actionLabel: 'Clear filter',
            onAction: query.clear,
          );
        }

        return ListView.separated(
          // Without this the list is greedy: `Flexible` hands it the dialog's
          // whole remaining height and it takes all of it, so the Column's
          // `mainAxisSize.min` never shrink-wraps and a two-row dialog stands
          // 600px tall with the middle empty. Measured, not reasoned about —
          // `getRect` on the dialog read 600.0 before this line.
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          itemCount: matches.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          // Each tile watches the theme itself — required, since a
          // ListView.builder keeps its children across the parent's rebuilds
          // and they'd otherwise stay on the old theme's colours.
          itemBuilder: (context, i) => ShelfModelTile(model: matches[i]),
        );
      },
    );
  }
}

/// The tab's empty states, padded to sit where a list would.
///
/// Wraps the shared [EmptyState] rather than hand-rolling a Column — the app has
/// one of these and it carries the right type scale and action button.
class _Empty extends StatelessWidget {
  const _Empty({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: EmptyState(
        icon: icon,
        title: title,
        message: message,
        action: TextButton(onPressed: onAction, child: Text(actionLabel)),
      ),
    );
  }
}
