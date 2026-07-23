import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/auth/logic/session_controller.dart';
import '../../../features/network/logic/grid_overview_provider.dart';
import '../../../infrastructure/api/models/grid_overview.dart';
import '../../theme/app_theme.dart';
import 'top_bar_pill.dart';

/// What's live on the active grid, at a glance: how many computers are hosting
/// and how many models they serve. This is the top bar's "nodes + models hosting
/// in the grid" surface — the numbers a user checks to know their grid can
/// actually answer a message.
///
/// Icons rather than words ("node"/"model" are jargon in primary copy), with a
/// plain-language tooltip. Owns its own [TopBarPill] and stays fully unmounted —
/// pill and all — when nothing is online, so the bar never shows a bare "0 · 0"
/// or a lone empty capsule.
class HostingSummary extends ConsumerWidget {
  const HostingSummary({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(selectedNetworkProvider) == null) {
      return const SizedBox.shrink();
    }

    // Through [gridOverviewProvider], not the family directly — same one-door
    // rule as [gridPowerProvider], and for the same reason: [gridModelsProvider]
    // below reaches the overview through the alias, so watching the family here
    // too would flush the same cache twice inside one build.
    final nodes =
        ref.watch(gridOverviewProvider).asData?.value.nodes ??
        const <OverviewNode>[];
    final online = nodes.where((n) => n.online).length;
    final models = ref.watch(gridModelsProvider).length;
    if (online == 0 && models == 0) return const SizedBox.shrink();

    final computers = online == 1 ? '1 computer' : '$online computers';
    final serves = models == 1 ? '1 model' : '$models models';
    return TopBarPill(
      child: Tooltip(
        message: '$computers hosting · $serves available',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _HostingStat(icon: Icons.dns_outlined, value: online),
            const SizedBox(width: 12),
            _HostingStat(icon: Icons.auto_awesome_outlined, value: models),
          ],
        ),
      ),
    );
  }
}

class _HostingStat extends StatelessWidget {
  const _HostingStat({required this.icon, required this.value});

  final IconData icon;
  final int value;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: AppPalette.textSecondary),
        const SizedBox(width: 5),
        Text(
          '$value',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: AppPalette.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
