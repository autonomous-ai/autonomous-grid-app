/// The computer this phone is a remote control for.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grid_theme/grid_theme.dart';

import '../logic/phone_link_controller.dart';
import 'appearance_section.dart';
import 'parts.dart';

/// Which computer, and the one thing there is to change about it.
class SettingsTab extends ConsumerWidget {
  const SettingsTab(this.link, {super.key});

  /// What the computer told us about itself.
  final PhoneLinkConnected link;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      children: [
        const SectionLabel('Paired computer'),
        _HostCard(link),
        const SizedBox(height: 28),
        const AppearanceSection(),
        const SizedBox(height: 28),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(44),
          ),
          onPressed: () => ref.read(phoneLinkProvider.notifier).unpair(),
          child: const Text('Forget this computer'),
        ),
        const SizedBox(height: 8),
        Text(
          'This phone stops being able to reach it. Pair again with a new code '
          'from Grid on the computer, under Settings ▸ Phone.',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: AppPalette.textFaint),
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
