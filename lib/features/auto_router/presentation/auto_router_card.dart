import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/app_spinner.dart';
import '../../provider_node/presentation/engine_block.dart';
import '../logic/auto_router_controller.dart';
import '../logic/auto_router_models.dart';
import 'advisor_picker_dialog.dart';

/// Owner-only control for auto-routing (the reserved `auto` model). Turns it on
/// or off for the active grid and shows the advisor chain that ranks models for
/// each request. Only mounted for a grid the viewer owns (the CLI's router
/// commands are owner-level) — see the gate in `ProviderView`.
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

  Future<void> _editAdvisors(AutoRouterConfig config) async {
    final chosen = await showAdvisorPicker(
      context,
      ref,
      current: [for (final advisor in config.advisors) advisor.token],
    );
    if (chosen == null || chosen.isEmpty) return;
    await _run(() => _controller.setAdvisors(chosen));
  }

  /// Flip auto-routing. Turning it ON with no advisor configured yet would be
  /// rejected ("Configure an advisor first"), so we open the picker, then set the
  /// chain and enable together. Cancelling the picker leaves it off.
  Future<void> _toggle(AutoRouterConfig config, bool on) async {
    if (!on) {
      await _run(() => _controller.setEnabled(false));
      return;
    }
    if (config.hasAdvisors) {
      await _run(() => _controller.setEnabled(true));
      return;
    }
    final chosen = await showAdvisorPicker(context, ref, current: const []);
    if (chosen == null || chosen.isEmpty) return;
    await _run(() => _controller.enableWithAdvisors(chosen));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(autoRouterControllerProvider);
    return EngineBlock(
      icon: Icons.alt_route,
      title: 'Automatic model routing',
      subtitle:
          'When an app asks for the “auto” model, a cloud AI picks which of your '
          'grid’s models answers each message. Optional — your models work '
          'without it.',
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
                    ? 'On — the grid answers “auto” by picking a model per request.'
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
          if (config.hasAdvisors)
            _AdvisorChips(advisors: config.advisors)
          else
            _NeedsAdvisorsNote(),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : () => _editAdvisors(config),
              icon: const Icon(Icons.tune, size: 18),
              label: Text(
                config.hasAdvisors ? 'Edit advisors' : 'Choose advisors',
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The advisor chain as ordered chips — the models the router consults to rank
/// candidates, priority first.
class _AdvisorChips extends StatelessWidget {
  const _AdvisorChips({required this.advisors});

  final List<Advisor> advisors;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final advisor in advisors)
          Chip(
            label: Text(advisor.token),
            labelStyle: theme.textTheme.bodySmall,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
      ],
    );
  }
}

/// Shown when routing is on but no advisor is set — routing can't rank models
/// without one, so this nudges the owner to choose at least one.
class _NeedsAdvisorsNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, size: 18, color: theme.colorScheme.tertiary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Choose at least one advisor so routing has something to rank models '
            'with.',
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
