/// The rows and lines the first-run choice screen is made of — one per way a
/// grid can get a model, plus the two that defer it.
///
/// Split from the screen because the screen's own job is deciding *which* of
/// these a given machine can honestly offer; each widget here answers only for
/// itself, and hides when its way in isn't available.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/state/models/network_credential.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/chatgpt_logo.dart';
import '../../../../shared/widgets/choice_row.dart';
import '../../../provider_node/logic/api_engine_catalog.dart';
import '../../../provider_node/logic/api_engine_choices.dart';
import '../../../provider_node/logic/engine_slots.dart';
import '../../../provider_node/logic/provider_run_controller.dart';
import '../../../provider_node/logic/serving_engines_provider.dart';
import '../../../provider_node/presentation/api_engine_block.dart';
import '../../logic/onboarding_choice_controller.dart';

/// Sign in with a ChatGPT / Codex subscription — the quickest way in when the
/// installed CLI offers one: nothing to download, no key to go and find.
///
/// No form and no model picker: the subscription's whole model list is shared
/// (the CLI's own default), and choosing between them is a Model Engines
/// decision, not a first-screen one. Renders nothing when this CLI whitelists no
/// sign-in provider, so the screen never offers a road it can't walk.
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

    // The gap to the next option belongs to the option, not to the screen: this
    // one hides itself on a CLI with no sign-in provider, and a gap the screen
    // owned would stay behind as a hole.
    return _Option(
      child: ChoiceRow(
        // The vendor's own mark: this hands a ChatGPT account over, so it
        // reads as their sign-in rather than one of ours.
        icon: const ChatGptLogo(size: 18),
        title: 'Continue with ChatGPT',
        line: 'Sign in with your ChatGPT account.',
        badge: 'No setup',
        // The browser is where the account is approved, and the outward arrow
        // says so before the window changes under them.
        action: ChoiceRowAction.leave,
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

    return _Option(
      child: ChoiceRow(
        icon: const Icon(Icons.computer_outlined),
        title: 'Run locally',
        // No download figure: the model comes from `grid catalog`, which reports
        // no size, and a number invented here would be a promise the download
        // desk can't keep.
        line: 'Nothing leaves this computer. Downloads several GB.',
        badge: 'Private & offline',
        action: ChoiceRowAction.open,
        busy: state is OnboardingInstallingLocal,
        onPressed: controller.chooseLocal,
        child: switch (state) {
          OnboardingLocalFailed(:final message) => FailedRow(
            message: message,
            onRetry: controller.chooseLocal,
          ),
          _ => null,
        },
      ),
    );
  }
}

/// One option, on a surface of its own with the gap to the next one built in.
///
/// Two separated targets read as two choices; the single hairline-split block
/// the Model Engines tab uses reads as a list to work through, which is the
/// wrong shape for a screen whose whole job is one decision.
class _Option extends StatelessWidget {
  const _Option({required this.child});

  final ChoiceRow child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: ChoiceRowGroup(children: [child]),
  );
}

/// The key path, folded away: a line the user opens only if a key is how they
/// get in.
///
/// Not a third row. Pasting a key is the rarest of the three ways and the only
/// one that asks for something the user has to go and find — as a row of equal
/// weight it made a two-choice screen look like a form. Renders nothing when the
/// installed CLI takes no keys.
class ApiKeyDisclosure extends ConsumerStatefulWidget {
  const ApiKeyDisclosure({super.key, required this.network});

  final NetworkCredential network;

  @override
  ConsumerState<ApiKeyDisclosure> createState() => _ApiKeyDisclosureState();
}

class _ApiKeyDisclosureState extends ConsumerState<ApiKeyDisclosure> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final available = ref.watch(apiEnginesProvider).asData?.value ?? const [];
    final engines = keyEngines(available);
    if (engines.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: TextButton(
            onPressed: () => setState(() => _open = !_open),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Connect with an API key instead'),
                const SizedBox(width: 4),
                // Points down at what it opened — the same turn the choice rows
                // use, so one chevron language runs through the screen.
                AnimatedRotation(
                  turns: _open ? 0.5 : 0,
                  duration: AppMotion.hover,
                  curve: AppMotion.curve,
                  child: const Icon(Icons.expand_more_rounded, size: 18),
                ),
              ],
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: ApiEngineForm(
              network: widget.network,
              engines: engines,
              alreadyShared: apiModelsServed(ref.watch(servingEnginesProvider)),
              compact: true,
            ),
          ),
      ],
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 0, 14, 14),
      child: Column(
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
      ),
    );
  }
}
