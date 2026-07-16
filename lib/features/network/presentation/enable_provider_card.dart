import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/layouts/shell_state.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/log_view.dart';
import '../logic/enable_provider_controller.dart';

/// Shown on the Engines screen when the viewer can't share a model on the open
/// grid yet. An admin gets a one-click "turn it on" (it grants the provider role
/// and refreshes the token — see [EnableProviderController]); everyone else gets
/// [_SharingNotAllowed], which points them at a grid they *can* share on.
class EnableProviderCard extends ConsumerWidget {
  const EnableProviderCard({super.key, required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (network.role != NetworkRole.admin) return const _SharingNotAllowed();

    final state = ref.watch(enableProviderControllerProvider);
    final running =
        state is EnableRunning && state.networkId == network.networkId
        ? state
        : null;
    final failed = state is EnableFailed && state.networkId == network.networkId
        ? state
        : null;

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: running != null
          ? _Running(log: running.log)
          : _Idle(network: network, error: failed?.message),
    );
  }
}

/// The "you may use this grid, but not share on it" state — a grid someone else
/// owns and hasn't allowed you to host on. It's a card, not a bare line of text,
/// because it must not dead-end: every signed-in user owns at least one grid, so
/// it sends them there, and the engine set-up below stays available regardless.
class _SharingNotAllowed extends ConsumerWidget {
  const _SharingNotAllowed();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("You can use this grid, but not share on it"),
          const SizedBox(height: 4),
          Text(
            "Its owner hasn't allowed you to run a model here. You can still "
            'set up the engine below and share it on your own grid.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: () => ref
                .read(shellSectionProvider.notifier)
                .select(ShellSection.grids),
            icon: const Icon(Icons.bolt, size: 16),
            label: const Text('Open my grids'),
          ),
        ],
      ),
    );
  }
}

class _Idle extends ConsumerWidget {
  const _Idle({required this.network, this.error});
  final NetworkCredential network;
  final String? error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "You own this grid, but running an engine isn't turned on for "
          'your account yet.',
        ),
        const SizedBox(height: 4),
        Text(
          'Turn it on to run an engine from this computer below.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 10),
          Text(
            "Couldn't turn it on: $error",
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: () => ref
              .read(enableProviderControllerProvider.notifier)
              .enable(networkId: network.networkId, email: network.email),
          icon: const Icon(Icons.verified_user_outlined, size: 16),
          label: Text(error != null ? 'Try again' : 'Turn on engines'),
        ),
      ],
    );
  }
}

class _Running extends StatelessWidget {
  const _Running({required this.log});
  final List<String> log;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: const [
            AppSpinner(),
            SizedBox(width: 12),
            Text('Turning on engines…'),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(height: 120, child: LogView(lines: log)),
      ],
    );
  }
}
