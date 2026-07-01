import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/status_dot.dart';
import '../../playground/presentation/playground_dialog.dart';
import '../logic/grid_overview_provider.dart';
import 'consumer_env_card.dart';
import 'detail_widgets.dart';
import 'grid_overview_card.dart';
import 'members_tab.dart';

/// Right-hand detail pane for the selected network — Tailscale device-detail
/// style: a status header over the grid's content. Admins get a tabbed view
/// (Overview / Members) so they can manage who's on the grid.
class NetworkDetail extends ConsumerWidget {
  const NetworkDetail({super.key, required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
      child: _Header(network: network),
    );

    // Member management is owner-only — gate the tab on the admin role.
    if (network.role != NetworkRole.admin) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [header, Expanded(child: _OverviewTab(network: network))],
      );
    }

    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            dividerColor: Colors.transparent,
            tabs: [Tab(text: 'Overview'), Tab(text: 'Members')],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _OverviewTab(network: network),
                MembersTab(network: network),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The grid's overview content (stats, connection, role-specific cards, and
/// actions) — the default tab, also shown on its own for non-admins.
class _OverviewTab extends StatelessWidget {
  const _OverviewTab({required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 6, 24, 24),
      children: [
        const GridOverviewView(),
        const SizedBox(height: 22),
        // API access shown directly (as before — no developer expander).
        ConsumerEnvCard(network: network),
        const SizedBox(height: 20),
        _Actions(network: network),
        // Connection block (grid address) temporarily hidden per request:
        // const SizedBox(height: 20),
        // DetailSection(
        //   title: 'Connection',
        //   children: [
        //     AddressRow(label: 'Grid address', value: network.lanSignalingUrl),
        //   ],
        // ),
      ],
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.network});
  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // The grid's live operational state from its API: "running" when a node is
    // serving it, anything else (stopped, still loading, or unreachable) reads
    // as Stopped. One operational vocabulary — never the access-token state.
    final state = ref.watch(gridOverviewProvider).asData?.value.state;
    final running = state?.toLowerCase() == 'running';
    final label = running ? 'Running' : 'Stopped';
    final color = running ? AppPalette.online : AppPalette.offline;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(network.name,
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w600, fontSize: 22)),
            ),
            const SizedBox(width: 12),
            GridBadges(network: network),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            StatusDot(color: color, size: 9),
            const SizedBox(width: 8),
            Text(label,
                style: theme.textTheme.bodyMedium?.copyWith(color: color)),
          ],
        ),
      ],
    );
  }
}

class _Actions extends ConsumerWidget {
  const _Actions({required this.network});
  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canProvide = network.canManageProvider;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        // Setting up an engine is the main action for provider-capable grids.
        // This opens the Engines tab (the real "Start engine" lives there once a
        // model is ready) — so it's labelled "Set up engine", not "Start".
        if (canProvide)
          FilledButton.icon(
            onPressed: () =>
                ref.read(navSectionProvider.notifier).select(NavSection.provider),
            icon: const Icon(Icons.dns_outlined, size: 18),
            label: const Text('Set up engine'),
          ),
        // Quick smoke test — opens the throwaway chat dialog. It's the primary
        // action for pure consumers, who can't run an engine of their own.
        _TestModelButton(primary: !canProvide),
      ],
    );
  }
}

/// Opens the quick model-test dialog. Emphasised (filled) when it's the grid's
/// primary action — i.e. for pure consumers who can't set up an engine.
class _TestModelButton extends ConsumerWidget {
  const _TestModelButton({required this.primary});
  final bool primary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void open() => openPlaygroundDialog(context, ref);
    const icon = Icon(Icons.chat_bubble_outline, size: 16);
    const label = Text('Test a model');
    return primary
        ? FilledButton.icon(onPressed: open, icon: icon, label: label)
        : OutlinedButton.icon(onPressed: open, icon: icon, label: label);
  }
}
