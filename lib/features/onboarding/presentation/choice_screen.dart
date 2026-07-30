import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/onboarding_store.dart';
import '../../../shared/layouts/onboarding_page.dart';
import '../../../shared/theme/app_theme.dart';
import '../../auth/logic/session_controller.dart';
import '../../node_setup/logic/auto_host_controller.dart';
import '../../provider_node/logic/provider_run_controller.dart';
import '../logic/onboarding_choice_controller.dart';
import 'widgets/api_key_disclosure.dart';
import 'widgets/choice_options.dart';

/// First-run choice: the user's grid has no model to chat with yet, so ask how
/// it should get one.
///
/// Two rows carry the decision, in the order they cost the user something —
/// share a coding CLI already signed in here (nothing to fetch or find), or run
/// a model on this computer (a download). Each is a title, one line, and a badge
/// naming what it saves you; the detail belongs after the choice, not in front
/// of it. The key path is folded away underneath, because it's the rarest way in
/// and the only one that sends the user off to find something first.
///
/// Every option hides itself when this machine or the installed CLI can't offer
/// it, and "I'll set this up later" is always there — the screen is a fork, not
/// a wall.
class OnboardingChoiceScreen extends ConsumerWidget {
  const OnboardingChoiceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Starting the cloud engine *is* the "use a hosted model" choice — but only
    // once it's actually serving. The shared Cloud-Provider block starts the
    // engine without knowing it's inside onboarding, so onboarding records the
    // choice here, and only when the join has finished serving
    // (`starting == false`). Deciding on the transient "starting" state jumped
    // the user into a chat with nothing serving.
    ref.listen(providerRunControllerProvider, (_, next) {
      if (next is ProviderRunActive && !next.starting) {
        ref
            .read(onboardingDecisionProvider.notifier)
            .decide(OnboardingDecision.openai);
      }
    });

    final network = ref.watch(selectedNetworkProvider);

    return OnboardingPage(
      title: 'Connect an AI model',
      // Says the decision is reversible up front, which is what lets the rest of
      // the screen stay this short.
      subtitle: 'Choose where your AI runs. You can change this later.',
      children: [
        // One row per way in, quickest first. Each hides itself when this
        // computer or the installed CLI can't offer it — and carries its own
        // gap, so a hidden option leaves no hole.
        if (network != null) SeatOption(network: network),
        if (ref.watch(supportsBuiltInEngineProvider)) const LocalOption(),
        if (network != null) ...[
          const CloudStartError(),
          ApiKeyDisclosure(network: network),
        ],
        const SizedBox(height: 4),
        Center(
          child: TextButton(
            onPressed: () => ref
                .read(onboardingChoiceControllerProvider.notifier)
                .chooseLater(),
            // Quiet, not accent — it's the way out, not one of the answers. Not
            // `textFaint` though: that reads at 3.3:1 on this white page, and a
            // control has to clear 4.5 (§11).
            style: TextButton.styleFrom(
              foregroundColor: AppPalette.textSecondary,
            ),
            child: const Text('I’ll set this up later'),
          ),
        ),
      ],
    );
  }
}
