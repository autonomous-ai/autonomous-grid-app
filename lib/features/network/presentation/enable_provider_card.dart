import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/log_view.dart';
import '../logic/enable_provider_controller.dart';

/// Shown in the "Serve provider" section when the viewer administers a network
/// but the token lacks `provider:poll`. One click grants the provider role and
/// refreshes the token (see [EnableProviderController]). Non-admins just see
/// why they can't serve.
class EnableProviderCard extends ConsumerWidget {
  const EnableProviderCard({super.key, required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    if (network.role != NetworkRole.admin) {
      return Text(
        'This network token has no provider scope (provider:poll), so it '
        'cannot run a provider. Ask a network admin to grant you the '
        'provider role.',
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }

    final state = ref.watch(enableProviderControllerProvider);
    final running =
        state is EnableRunning && state.networkId == network.networkId
            ? state
            : null;
    final failed =
        state is EnableFailed && state.networkId == network.networkId
            ? state
            : null;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppPalette.divider),
      ),
      child: running != null
          ? _Running(log: running.log)
          : _Idle(network: network, error: failed?.message),
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
        Text("You're an admin here, but this token can't serve models yet "
            '(missing the provider:poll scope).'),
        const SizedBox(height: 4),
        Text(
          'Enable provider to grant your account the provider role and refresh '
          'your token — then you can start serving the model below.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        if (error != null) ...[
          const SizedBox(height: 10),
          Text('Failed: $error',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: () =>
              ref.read(enableProviderControllerProvider.notifier).enable(
                    networkId: network.networkId,
                    email: network.email,
                  ),
          icon: const Icon(Icons.verified_user_outlined, size: 16),
          label: Text(error != null
              ? 'Retry enabling provider'
              : 'Enable provider on this network'),
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
            SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 12),
            Text('Enabling provider…'),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(height: 120, child: LogView(lines: log)),
      ],
    );
  }
}
