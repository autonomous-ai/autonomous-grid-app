/// The rows the first-run choice screen is made of — one per way a grid can get
/// a model — plus what they say when one fails.
///
/// Split from the screen because the screen's own job is deciding *which* of
/// these a given machine can honestly offer; each widget here answers only for
/// itself, and hides when its way in isn't available.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/widgets/choice_row.dart';
import '../../../provider_node/logic/provider_run_controller.dart';
import '../../logic/onboarding_choice_controller.dart';

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
/// A surface each, not the single hairline-split block the Share models tab
/// uses: that one reads as a list to work through, which is the wrong shape for
/// a screen whose whole job is one decision.
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
