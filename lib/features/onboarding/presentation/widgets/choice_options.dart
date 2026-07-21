/// The cards and lines the first-run choice screen is made of — one per way a
/// grid can get a model, plus the two that defer it.
///
/// Split from the screen because the screen's own job is deciding *which* of
/// these a given machine can honestly offer; each widget here answers only for
/// itself, and hides when its way in isn't available.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/state/models/network_credential.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../auth/logic/session_controller.dart';
import '../../../network/presentation/add_member_dialog.dart';
import '../../../provider_node/logic/api_engine_catalog.dart';
import '../../../provider_node/logic/engine_slots.dart';
import '../../../provider_node/logic/provider_run_controller.dart';
import '../../../provider_node/logic/serving_engines_provider.dart';
import '../../../provider_node/presentation/api_engine_block.dart';
import '../../../provider_node/presentation/engine_block.dart';
import '../../../provider_node/presentation/engine_cost_chip.dart';
import '../../logic/onboarding_choice_controller.dart';
import '../../logic/onboarding_routes.dart';

/// Sign in with a ChatGPT / Codex subscription — the quickest way in when the
/// installed CLI offers one: nothing to download, no key to go and find.
///
/// Renders nothing when this CLI whitelists no sign-in provider, so the screen
/// doesn't offer a road it can't walk.
class SubscriptionOption extends ConsumerWidget {
  const SubscriptionOption({super.key, required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engines = signInEngines(
      ref.watch(apiEnginesProvider).asData?.value ?? const [],
    );
    if (engines.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: EngineBlock(
        icon: Icons.auto_awesome_outlined,
        title: 'Continue with ChatGPT',
        subtitle:
            'Fastest way in — sign in with the subscription you already have. '
            'No key, no download.',
        trailing: const EngineCostChip(cost: EngineCost.metered),
        child: ApiEngineForm(
          network: network,
          engines: engines,
          alreadyShared: apiModelsServed(ref.watch(servingEnginesProvider)),
          compact: true,
        ),
      ),
    );
  }
}

/// Paste a key from a provider the user already pays for. Folded away by
/// default: it's the answer for someone who *has* a key, and asking everyone
/// else to scroll past a key field was what made this screen feel like setup.
class ApiKeyOption extends ConsumerWidget {
  const ApiKeyOption({super.key, required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final available = ref.watch(apiEnginesProvider).asData?.value ?? const [];
    final engines = keyEngines(available);
    if (engines.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: CollapsibleEngineBlock(
        icon: Icons.key_outlined,
        title: 'Use an API key',
        subtitle: apiKeyCardSubtitle(available),
        child: ApiEngineForm(
          network: network,
          engines: engines,
          alreadyShared: apiModelsServed(ref.watch(servingEnginesProvider)),
          compact: true,
        ),
      ),
    );
  }
}

/// Run a model on this computer: installs the engine here, then the model
/// downloads in the background and shares itself once the user is in.
class LocalOption extends ConsumerWidget {
  const LocalOption({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(onboardingChoiceControllerProvider);
    final controller = ref.read(onboardingChoiceControllerProvider.notifier);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: EngineBlock(
        icon: Icons.computer_outlined,
        title: 'Run it on this computer',
        subtitle:
            'Private, and free to use. Downloads a model (several GB) in the '
            'background, then shares it on your grid.',
        trailing: const EngineCostChip(cost: EngineCost.free),
        child: switch (state) {
          OnboardingInstallingLocal() => const BusyRow(
            label: 'Setting up the engine…',
          ),
          OnboardingLocalFailed(:final message) => FailedRow(
            message: message,
            onRetry: controller.chooseLocal,
          ),
          OnboardingChoiceIdle() => Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: controller.chooseLocal,
              icon: const Icon(Icons.download, size: 18),
              label: const Text('Download a model'),
            ),
          ),
        },
      ),
    );
  }
}

/// Ask someone else to run a model — a line, not a card: it's the one answer
/// that doesn't get this grid a model today, so it sits with "Skip for now"
/// rather than competing with the three that do. The invite is pre-filled with
/// the inviter's own email domain so they only type the person's name.
class InviteLine extends ConsumerWidget {
  const InviteLine({super.key, required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefill = inviteDomainPrefill(ref.watch(sessionProvider).userEmail);

    return Center(
      child: TextButton.icon(
        onPressed: () => AddMemberDialog.show(
          context,
          network.networkId,
          initialEmail: prefill,
        ),
        icon: const Icon(Icons.group_add_outlined, size: 16),
        label: const Text('Or ask a teammate to run one'),
      ),
    );
  }
}

/// The reason the last cloud "Sign in & share" didn't take, shown under the
/// Cloud-Provider block. Without it a failed join leaves the user staring at an
/// unchanged screen — e.g. trying to share on a grid they only consume on, where
/// the humanised message says exactly that (see `_humanizeJoinFailure`). Renders
/// nothing until there's a failure.
class CloudStartError extends ConsumerWidget {
  const CloudStartError({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final run = ref.watch(providerRunControllerProvider);
    if (run is! ProviderRunFailed) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        run.message,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      ),
    );
  }
}

/// A spinner + label while the local engine installs.
class BusyRow extends StatelessWidget {
  const BusyRow({super.key, required this.label});

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
class FailedRow extends StatelessWidget {
  const FailedRow({super.key, required this.message, required this.onRetry});

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
