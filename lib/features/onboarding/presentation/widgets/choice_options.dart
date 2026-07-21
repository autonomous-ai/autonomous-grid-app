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
import '../../../../shared/widgets/chatgpt_logo.dart';
import '../../../../shared/widgets/soft_action_button.dart';
import '../../../provider_node/logic/api_engine_catalog.dart';
import '../../../provider_node/logic/engine_slots.dart';
import '../../../provider_node/logic/provider_run_controller.dart';
import '../../../provider_node/logic/serving_engines_provider.dart';
import '../../../provider_node/presentation/api_engine_block.dart';
import '../../logic/onboarding_choice_controller.dart';
import '../../logic/onboarding_routes.dart';
import 'choice_card.dart';

/// Sign in with a ChatGPT / Codex subscription — the quickest way in when the
/// installed CLI offers one: nothing to download, no key to go and find.
///
/// One button, no form: the subscription's whole model list is shared (the CLI's
/// own default), and choosing between them is a Model Engines decision, not a
/// first-screen one. Renders nothing when this CLI whitelists no sign-in
/// provider, so the screen never offers a road it can't walk.
class SubscriptionOption extends ConsumerWidget {
  const SubscriptionOption({super.key, required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engines = signInEngines(
      ref.watch(apiEnginesProvider).asData?.value ?? const [],
    );
    if (engines.isEmpty) return const SizedBox.shrink();
    final provider = engines.first.provider;

    final run = ref.watch(providerRunControllerProvider);
    final starting =
        run is ProviderRunActive &&
        run.grid == network.networkId &&
        run.starting;

    return ChoiceCard(
      icon: Icons.auto_awesome_outlined,
      title: 'Continue with ChatGPT',
      line: 'Fastest setup — sign in with your subscription',
      // The vendor's mark at its own colours: this button hands a ChatGPT
      // account over, so it reads as their sign-in, not one of ours. The label
      // says the action, not the provider — the card's title already named it.
      action: SoftActionButton(
        leading: const ChatGptLogo(size: 18),
        label: 'Sign in',
        compact: true,
        busy: starting,
        onPressed: () => ref
            .read(providerRunControllerProvider.notifier)
            .startApiEngine(
              network: network.networkId,
              kind: provider.kind,
              envVar: provider.envVar,
              apiKey: '',
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

    return ChoiceCard(
      icon: Icons.computer_outlined,
      title: 'Run locally',
      line: 'Private & offline — downloads a model (several GB)',
      action: SoftActionButton(
        leading: const Icon(Icons.download_rounded, size: 18),
        label: 'Download a model',
        compact: true,
        busy: state is OnboardingInstallingLocal,
        onPressed: controller.chooseLocal,
      ),
      footer: switch (state) {
        OnboardingLocalFailed(:final message) => FailedRow(
          message: message,
          onRetry: controller.chooseLocal,
        ),
        _ => null,
      },
    );
  }
}

/// Paste a key from a provider the user already pays for. The key field only
/// appears once they say this is their way in — asking everyone else to scroll
/// past it was what made this screen feel like setup.
class ApiKeyOption extends ConsumerStatefulWidget {
  const ApiKeyOption({super.key, required this.network});

  final NetworkCredential network;

  @override
  ConsumerState<ApiKeyOption> createState() => _ApiKeyOptionState();
}

class _ApiKeyOptionState extends ConsumerState<ApiKeyOption> {
  bool _connecting = false;

  @override
  Widget build(BuildContext context) {
    final available = ref.watch(apiEnginesProvider).asData?.value ?? const [];
    final engines = keyEngines(available);
    if (engines.isEmpty) return const SizedBox.shrink();

    return ChoiceCard(
      icon: Icons.key_outlined,
      title: 'Use an API key',
      line: apiKeyCardLine(available),
      action: SoftActionButton(
        leading: const Icon(Icons.vpn_key_outlined, size: 18),
        label: 'Enter a key',
        compact: true,
        onPressed: () => setState(() => _connecting = true),
      ),
      footer: _connecting
          ? ApiEngineForm(
              network: widget.network,
              engines: engines,
              alreadyShared: apiModelsServed(ref.watch(servingEnginesProvider)),
              compact: true,
            )
          : null,
    );
  }
}

/// The reason the last cloud start didn't take. Without it a failed join leaves
/// the user staring at an unchanged screen — e.g. trying to share on a grid they
/// only consume on, where the humanised message says exactly that (see
/// `_humanizeJoinFailure`). Renders nothing until there's a failure.
class CloudStartError extends ConsumerWidget {
  const CloudStartError({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final run = ref.watch(providerRunControllerProvider);
    if (run is! ProviderRunFailed) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        run.message,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      ),
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
