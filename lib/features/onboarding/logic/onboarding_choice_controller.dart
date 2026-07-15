import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/onboarding_store.dart';
import '../../node_setup/logic/node_capabilities.dart';
import '../../node_setup/logic/node_setup_controller.dart';
import '../../node_setup/logic/node_setup_plan.dart';

/// State of the "run a model on this computer" action on the choice screen.
///
/// The other two paths finish elsewhere — the cloud engine through the shared
/// Cloud-Provider block, the invite through a dialog — so only the local
/// install, which this screen drives itself, needs a state of its own.
sealed class OnboardingChoiceState {
  const OnboardingChoiceState();
}

/// Nothing in flight — the card shows its "Set this up" button.
class OnboardingChoiceIdle extends OnboardingChoiceState {
  const OnboardingChoiceIdle();
}

/// Installing the built-in engine so a model can run on this computer.
class OnboardingInstallingLocal extends OnboardingChoiceState {
  const OnboardingInstallingLocal();
}

/// The local install stopped. [message] is a plain line for the card; the user
/// can try again or pick another path.
class OnboardingLocalFailed extends OnboardingChoiceState {
  const OnboardingLocalFailed(this.message);
  final String message;
}

final onboardingChoiceControllerProvider =
    NotifierProvider<OnboardingChoiceController, OnboardingChoiceState>(
      OnboardingChoiceController.new,
    );

/// Drives the choice screen's local path and records the decision.
///
/// "Run local" installs only the engine here — the model (several GB) downloads
/// in the background once the user is in, exactly as before (see
/// `BackgroundModelController`), which also shares it. The escape path just
/// records the decision so the screen isn't shown again.
class OnboardingChoiceController extends Notifier<OnboardingChoiceState> {
  @override
  OnboardingChoiceState build() => const OnboardingChoiceIdle();

  /// Install the built-in engine, then remember the local path. On success the
  /// screen falls away (the route recomputes to the app) and the background
  /// download + share take over; on failure the card shows why.
  Future<void> chooseLocal() async {
    if (state is OnboardingInstallingLocal) return;
    state = const OnboardingInstallingLocal();

    final caps = await ref.read(nodeCapabilitiesProvider.future);
    // The engine (and the assistant, if somehow still missing) — never the
    // model, which downloads in the background, and never the media engine.
    final plan = buildSetupPlan(caps, includeModel: false, includeMedia: false);
    if (plan.isNotEmpty) {
      await ref.read(nodeSetupControllerProvider.notifier).run(plan);
      final setup = ref.read(nodeSetupControllerProvider);
      if (setup is NodeSetupFailed) {
        state = OnboardingLocalFailed(setup.message);
        return;
      }
    }

    ref
        .read(onboardingDecisionProvider.notifier)
        .decide(OnboardingDecision.local);
    state = const OnboardingChoiceIdle();
  }

  /// Go into the app without hosting — the user will set a model up later, or
  /// wait for a teammate they invited to bring one online.
  void chooseLater() => ref
      .read(onboardingDecisionProvider.notifier)
      .decide(OnboardingDecision.later);
}

/// A polite pre-fill for the invite field: the user's own email domain with an
/// `@`, so they only type the teammate's name — e.g. `dev@autonomous.ai` →
/// `@autonomous.ai`. Null when there's no usable domain (no email, or a
/// malformed one), so the field stays a plain placeholder rather than a lone
/// `@`.
String? inviteDomainPrefill(String? email) {
  if (email == null) return null;
  final at = email.lastIndexOf('@');
  if (at < 0 || at == email.length - 1) return null;
  final domain = email.substring(at + 1).trim();
  return domain.isEmpty ? null : '@$domain';
}
