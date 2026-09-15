/// What the phone shows once it is through: which computer, and what that
/// computer is signed in to.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/phone_link_controller.dart';
import 'chats_section.dart';
import 'parts.dart';
import 'projects_section.dart';

/// The connected screen.
class ConnectedView extends ConsumerWidget {
  const ConnectedView(this.link, {super.key});

  /// What the computer told us.
  final PhoneLinkConnected link;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    return ListView(
      // 24 on every side, the section padding the desktop uses.
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      children: [
        _HostCard(link),
        const SizedBox(height: 24),
        // Above the grids on purpose: the grids say what the computer is signed
        // in to, which changes about once a month; the chats are the thing
        // somebody opens this app to look at.
        const ChatsSection(),
        const ProjectsSection(),
        const SizedBox(height: 24),
        const SectionLabel('Grids'),
        if (link.grids.isEmpty)
          const _NoGrids()
        else
          // Short and bounded — this is every grid a person has joined, not a
          // feed. A Column is honest here; a builder would be cargo cult.
          ...link.grids.map((grid) => _GridTile(grid)),
        const SizedBox(height: 28),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(44),
          ),
          onPressed: () => ref.read(phoneLinkProvider.notifier).unpair(),
          child: const Text('Forget this computer'),
        ),
      ],
    );
  }
}

class _HostCard extends StatelessWidget {
  const _HostCard(this.link);

  final PhoneLinkConnected link;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return GridCard(
      child: Row(
        children: [
          const GridDot(live: true),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(link.hostName, style: theme.textTheme.titleSmall),
                RowDetail([
                  'Connected',
                  link.platform,
                  'Grid ${link.appVersion}',
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GridTile extends StatelessWidget {
  const _GridTile(this.grid);

  final GridRow grid;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return GridListRow(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            grid.name.isEmpty ? grid.id : grid.name,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          RowDetail([grid.type, grid.email]),
        ],
      ),
    );
  }
}

class _NoGrids extends StatelessWidget {
  const _NoGrids();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Text(
      "Your computer isn't signed in to a grid yet. Sign in over there, then "
      'tap refresh.',
      style: Theme.of(
        context,
      ).textTheme.bodyMedium?.copyWith(color: AppPalette.textSecondary),
    );
  }
}
