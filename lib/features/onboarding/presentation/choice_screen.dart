import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../infrastructure/state/onboarding_store.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../auth/logic/session_controller.dart';
import '../../network/presentation/add_member_dialog.dart';
import '../../node_setup/logic/auto_host_controller.dart';
import '../../provider_node/logic/provider_run_controller.dart';
import '../../provider_node/presentation/api_engine_block.dart';
import '../../provider_node/presentation/engine_block.dart';
import '../logic/onboarding_choice_controller.dart';

/// First-run choice: the user's grid has no model to chat with yet, so ask how
/// it should get one — run a model on this computer, connect a hosted provider
/// (OpenAI) with an API key, or invite a teammate to bring one online. There's
/// always a way in without committing ("set this up later"), so the screen is a
/// fork, not a wall.
class OnboardingChoiceScreen extends ConsumerWidget {
  const OnboardingChoiceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Starting the cloud engine *is* the "use OpenAI" choice — record it, and the
    // route falls through to the app. Done here because the shared Cloud-Provider
    // block starts the engine without knowing it's inside onboarding.
    ref.listen(providerRunControllerProvider, (_, next) {
      if (next is ProviderRunActive) {
        ref
            .read(onboardingDecisionProvider.notifier)
            .decide(OnboardingDecision.openai);
      }
    });

    final network = ref.watch(selectedNetworkProvider);
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: AppPalette.windowBg,
      // Scrollable: the window can be resized small and the cloud form is tall —
      // the options must never be clipped.
      body: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Bring a model to your grid',
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Your grid has nothing to chat with yet. Choose how it gets '
                    'a model — you can change this later.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (network != null) ...[
                    // The Cloud-Provider block hides itself when the installed CLI
                    // whitelists no hosted provider, so it may render nothing.
                    // Compact here: onboarding is a lean fork, not the full
                    // Model Engines config screen.
                    ApiEngineBlock(network: network, compact: true),
                    const SizedBox(height: 12),
                  ],
                  if (ref.watch(supportsBuiltInEngineProvider)) ...[
                    const _LocalOption(),
                    const SizedBox(height: 12),
                  ],
                  if (network != null && network.isOwner) ...[
                    _InviteOption(network: network),
                    const SizedBox(height: 12),
                  ],
                  const SizedBox(height: 4),
                  Center(
                    child: TextButton(
                      onPressed: () => ref
                          .read(onboardingChoiceControllerProvider.notifier)
                          .chooseLater(),
                      child: const Text("I'll set this up later"),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Run a model on this computer: installs the engine here, then the model
/// downloads in the background and shares itself once the user is in.
class _LocalOption extends ConsumerWidget {
  const _LocalOption();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(onboardingChoiceControllerProvider);
    final controller = ref.read(onboardingChoiceControllerProvider.notifier);

    return EngineBlock(
      icon: Icons.computer_outlined,
      title: 'Run a model on this computer',
      subtitle:
          'Private and free to use. Downloads a model (several GB) in the '
          'background after setup, then shares it on your grid.',
      child: switch (state) {
        OnboardingInstallingLocal() => const _BusyRow(
          label: 'Setting up the engine…',
        ),
        OnboardingLocalFailed(:final message) => _FailedRow(
          message: message,
          onRetry: controller.chooseLocal,
        ),
        OnboardingChoiceIdle() => Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: controller.chooseLocal,
            icon: const Icon(Icons.download, size: 18),
            label: const Text('Set this up'),
          ),
        ),
      },
    );
  }
}

/// Invite a teammate to bring a model online — the field is pre-filled with the
/// inviter's own email domain so they only type the person's name.
class _InviteOption extends ConsumerWidget {
  const _InviteOption({required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefill = inviteDomainPrefill(ref.watch(sessionProvider).userEmail);

    return EngineBlock(
      icon: Icons.group_add_outlined,
      title: 'Invite a teammate',
      subtitle: prefill == null
          ? 'Ask someone else to run a model, so your whole grid can use it.'
          : 'Ask someone at $prefill to run a model, so your whole grid can '
                'use it.',
      child: Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: () => AddMemberDialog.show(
            context,
            network.networkId,
            initialEmail: prefill,
          ),
          icon: const Icon(Icons.mail_outline, size: 18),
          label: const Text('Invite someone'),
        ),
      ),
    );
  }
}

/// A spinner + label while the local engine installs.
class _BusyRow extends StatelessWidget {
  const _BusyRow({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const AppSpinner(),
        const SizedBox(width: 12),
        Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// The local install failed — the plain reason plus a retry.
class _FailedRow extends StatelessWidget {
  const _FailedRow({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          message,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Try again'),
          ),
        ),
      ],
    );
  }
}
