import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../infrastructure/state/onboarding_store.dart';
import '../../../shared/theme/app_theme.dart';
import '../../auth/logic/session_controller.dart';
import '../../node_setup/logic/auto_host_controller.dart';
import '../../provider_node/logic/provider_run_controller.dart';
import '../logic/onboarding_choice_controller.dart';
import 'widgets/choice_options.dart';

/// First-run choice: the user's grid has no model to chat with yet, so ask how
/// it should get one.
///
/// Three cards, in the order they cost the user something — sign in with a
/// ChatGPT subscription (nothing to fetch or find), run a model on this computer
/// (a download), paste an API key (folded away; it's the answer for someone who
/// already has one). Asking a teammate and deciding later are lines underneath,
/// because neither gets this grid a model today. Every card hides itself when
/// this machine or the installed CLI can't offer it, and there's always a way
/// past — the screen is a fork, not a wall.
class OnboardingChoiceScreen extends ConsumerWidget {
  const OnboardingChoiceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Starting the cloud engine *is* the "use OpenAI" choice — but only once it's
    // actually serving. The shared Cloud-Provider block starts the engine without
    // knowing it's inside onboarding, so onboarding wires the two ends here:
    //  - a sign-in join (codex OAuth) streams an authorize URL to approve — open
    //    it the instant it arrives, exactly like the Model Engines and login
    //    screens (the block itself doesn't open the browser);
    //  - record the choice and fall through to the app only when the join has
    //    finished serving (`starting == false`). Deciding on the transient
    //    "starting" state jumped the user into a chat with nothing serving,
    //    before the browser sign-in had even opened.
    ref.listen(providerRunControllerProvider, (prev, next) {
      final wasUrl = prev is ProviderRunActive ? prev.signInUrl : null;
      final nowUrl = next is ProviderRunActive ? next.signInUrl : null;
      if (nowUrl != null && nowUrl != wasUrl) _openInBrowser(nowUrl);

      if (next is ProviderRunActive && !next.starting) {
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
                  // One card per way in, quickest first: sign in with a
                  // subscription, run a model here, or paste a key. Each hides
                  // itself when this computer or the installed CLI can't offer
                  // it, so the screen never shows a road that leads nowhere.
                  if (network != null) SubscriptionOption(network: network),
                  if (ref.watch(supportsBuiltInEngineProvider))
                    const LocalOption(),
                  if (network != null) ...[
                    ApiKeyOption(network: network),
                    const CloudStartError(),
                  ],
                  const SizedBox(height: 8),
                  // The fourth way in — someone else's computer — is a line
                  // rather than a card: it's the only one that doesn't get the
                  // grid a model today, and it's an owner's option alone.
                  if (network != null && network.isOwner)
                    InviteLine(network: network),
                  Center(
                    child: TextButton(
                      onPressed: () => ref
                          .read(onboardingChoiceControllerProvider.notifier)
                          .chooseLater(),
                      child: const Text('Skip for now'),
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

/// Opens [url] in the user's default browser; best-effort (the running block
/// still shows the URL as a tappable fallback). Mirrors the Model Engines and
/// login screens so a sign-in join opens the browser the same way.
Future<void> _openInBrowser(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
