/// The two rows the first-run choice screen is made of — one per way a grid can
/// get a model — plus what they say when one fails.
///
/// Split from the screen because the screen's own job is deciding *which* of
/// these a given machine can honestly offer; each widget here answers only for
/// itself, and hides when its way in isn't available.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/state/models/network_credential.dart';
import '../../../../shared/widgets/choice_row.dart';
import '../../../provider_node/logic/api_engine_catalog.dart';
import '../../../provider_node/logic/api_engine_choices.dart';
import '../../../provider_node/logic/provider_run_controller.dart';
import '../../logic/onboarding_choice_controller.dart';

/// Share a coding CLI this computer already has signed in (Claude Code, Codex) —
/// the quickest way in when there is one: nothing to download, no key to go and
/// find, and no account to hand over.
///
/// No form and no model picker: the CLI's whole tier list is shared (the grid's
/// own default), and choosing between them is a Model Engines decision, not a
/// first-screen one. Renders nothing when this machine has no such CLI, so the
/// screen never offers a road it can't walk.
class SeatOption extends ConsumerWidget {
  const SeatOption({super.key, required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final available = ref.watch(apiEnginesProvider).asData?.value ?? const [];
    final engines = seatEngines(available);
    if (engines.isEmpty) return const SizedBox.shrink();
    final provider = engines.first.provider;

    final run = ref.watch(providerRunControllerProvider);
    final starting =
        run is ProviderRunActive &&
        run.grid == network.networkId &&
        run.starting;

    // The gap to the next option belongs to the option, not to the screen: this
    // one hides itself on a machine with no such CLI, and a gap the screen owned
    // would stay behind as a hole.
    return _Option(
      child: ChoiceRow(
        icon: const Icon(Icons.terminal_outlined),
        title: seatCardTitle(available),
        line: 'Use the ${provider.label} you already have here.',
        badge: 'No setup',
        // Nothing opens and nothing is handed off: the press starts the join
        // right here, and the row spins until it is serving.
        action: ChoiceRowAction.act,
        busy: starting,
        onPressed: () => ref
            .read(providerRunControllerProvider.notifier)
            .startApiEngine(
              network: network.networkId,
              provider: provider,
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
        // The cost, since the badge already carries the benefit — and one line,
        // not two. No figure: the model comes from `grid catalog`, which reports
        // no size, and a number invented here would be a promise the download
        // desk can't keep.
        line: 'Downloads a model — several GB.',
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
    // Outlined: these sit on the onboarding card's white, where the tabs'
    // white-on-tinted surface leaves nothing on screen to press.
    child: ChoiceRowGroup(outlined: true, children: [child]),
  );
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
