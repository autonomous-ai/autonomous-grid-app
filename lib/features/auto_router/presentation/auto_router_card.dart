import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/app_spinner.dart';
import '../../models/logic/advertise_name.dart';
import '../../network/logic/grid_overview_provider.dart';
import '../../provider_node/presentation/engine_block.dart';
import '../logic/auto_router_controller.dart';
import '../logic/auto_router_models.dart';
import 'advisor_picker_dialog.dart';

/// Owner-only control for auto-routing (the reserved `auto` model). One switch
/// turns it on over the grid's running models — an app asking for `auto` then
/// gets the best of them per request, with no model to pick. Which cloud AI
/// makes that choice is a platform default, tucked behind an advanced step, so
/// the owner never has to reason about advisors. Only mounted for a grid the
/// viewer owns (router commands are owner-level) — see the gate in `ProviderView`.
class AutoRouterCard extends ConsumerStatefulWidget {
  const AutoRouterCard({super.key});

  @override
  ConsumerState<AutoRouterCard> createState() => _AutoRouterCardState();
}

class _AutoRouterCardState extends ConsumerState<AutoRouterCard> {
  bool _busy = false;

  AutoRouterController get _controller =>
      ref.read(autoRouterControllerProvider.notifier);

  /// Run a mutation with the card's own busy flag held around it, so the switch
  /// and buttons disable while the grid applies the change.
  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Flip auto-routing. Turning it on configures the default deciding AI first
  /// when none is set (the control plane rejects `enable` without one), so the
  /// owner never sees an advisor picker on the main path.
  Future<void> _toggle(AutoRouterConfig config, bool on) {
    if (!on) return _run(() => _controller.setEnabled(false));
    if (config.hasAdvisors) return _run(() => _controller.setEnabled(true));
    return _run(() => _controller.enableWithDefaultAdvisor());
  }

  /// Advanced escape hatch: change which cloud AI decides the routing. Off the
  /// main flow — most owners leave the platform default.
  Future<void> _editAdvisors(AutoRouterConfig config) async {
    final chosen = await showAdvisorPicker(
      context,
      ref,
      current: [for (final advisor in config.advisors) advisor.token],
    );
    if (chosen == null || chosen.isEmpty) return;
    await _run(() => _controller.setAdvisors(chosen));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(autoRouterControllerProvider);
    return EngineBlock(
      icon: Icons.alt_route,
      title: 'Automatic model routing',
      subtitle:
          'When an app asks for the “auto” model, your grid answers with the '
          'best of your running models for each message — no model to pick. '
          'Optional.',
      child: state.when(
        skipLoadingOnReload: true,
        data: _body,
        error: (error, _) => _ErrorNote(
          message: '$error',
          onRetry: () => ref.invalidate(autoRouterControllerProvider),
        ),
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Align(alignment: Alignment.centerLeft, child: AppSpinner()),
        ),
      ),
    );
  }

  Widget _body(AutoRouterConfig config) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                config.enabled
                    ? 'On — apps can ask for “auto” and your grid picks a model '
                          'per request.'
                    : 'Off — apps must name a specific model.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            const SizedBox(width: 12),
            Switch(
              value: config.enabled,
              onChanged: _busy ? null : (value) => _toggle(config, value),
            ),
          ],
        ),
        if (config.enabled) ...[
          const SizedBox(height: 12),
          const _RoutingPool(),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy ? null : () => _editAdvisors(config),
              icon: const Icon(Icons.tune, size: 16),
              label: const Text('Advanced: choose the deciding AI'),
            ),
          ),
        ],
      ],
    );
  }
}

/// The grid's running models as the pool auto-routing chooses among — the live,
/// grid-wide list (every node's models, not just this computer), so the owner
/// sees exactly what `auto` can land on. All of them participate: the router
/// always considers the whole live set, so this is a read-only view, not a
/// selector. Empty until an engine is serving.
class _RoutingPool extends ConsumerWidget {
  const _RoutingPool();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // `gridChatModelIdsProvider` already drops media capabilities; also hide the
    // reserved `auto` itself, which the overview lists once routing is on.
    final models = [
      for (final id in ref.watch(gridChatModelIdsProvider))
        if (id != 'auto') id,
    ];
    if (models.isEmpty) {
      return _PoolNote(
        icon: Icons.info_outline,
        color: theme.colorScheme.tertiary,
        text: 'Start or add an engine so routing has models to choose from.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Auto chooses between your running models for each request:',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final id in models)
              Chip(
                label: Text(deriveAdvertiseName(id)),
                labelStyle: theme.textTheme.bodySmall,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
          ],
        ),
      ],
    );
  }
}

/// A one-line note with a leading icon — the routing pool's empty state.
class _PoolNote extends StatelessWidget {
  const _PoolNote({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// A compact error line with a retry, for when status can't be read (grid down,
/// session expired, not the owner).
class _ErrorNote extends StatelessWidget {
  const _ErrorNote({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    );
  }
}
