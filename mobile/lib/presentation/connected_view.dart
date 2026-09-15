/// What the phone shows once it is through: which computer, and what that
/// computer is signed in to.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/phone_link_controller.dart';
import 'chats_section.dart';
import 'projects_section.dart';

/// The connected screen.
class ConnectedView extends ConsumerWidget {
  const ConnectedView(this.link, {super.key});

  /// What the computer told us.
  final PhoneLinkConnected link;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _HostCard(link),
        const SizedBox(height: 24),
        // Above the grids on purpose: the grids say what the computer is signed
        // in to, which changes about once a month; the chats are the thing
        // somebody opens this app to look at.
        const ChatsSection(),
        const ProjectsSection(),
        const SizedBox(height: 24),
        Text('Grids', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (link.grids.isEmpty)
          const _NoGrids()
        else
          // Short and bounded — this is every grid a person has joined, not a
          // feed. A Column is honest here; a builder would be cargo cult.
          ...link.grids.map((grid) => _GridTile(grid)),
        const SizedBox(height: 32),
        OutlinedButton(
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
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: const BoxDecoration(
              color: Color(0xFF34C759),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(link.hostName, style: theme.textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(
                  'Connected · ${link.platform} · Grid ${link.appVersion}',
                  style: theme.textTheme.bodySmall,
                ),
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
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            grid.name.isEmpty ? grid.id : grid.name,
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 2),
          Text(
            [
              if (grid.type.isNotEmpty) grid.type,
              if (grid.email.isNotEmpty) grid.email,
            ].join(' · '),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _NoGrids extends StatelessWidget {
  const _NoGrids();

  @override
  Widget build(BuildContext context) => Text(
    "Your computer isn't signed in to a grid yet. Sign in over there, then "
    'tap refresh.',
    style: Theme.of(context).textTheme.bodyMedium,
  );
}
