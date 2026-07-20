import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/grid_overview.dart';
import '../../../infrastructure/state/onboarding_store.dart';
import '../../models/logic/engine_status.dart';
import '../../models/logic/models_providers.dart';
import '../../network/logic/grid_overview_provider.dart';
import '../../network/logic/node_display.dart';

/// Where onboarding sends the user once they're signed in with a grid and the
/// assistant is installed — the fork between "the grid can already chat" and
/// "ask how this grid gets a model".
enum OnboardingRoute {
  /// Still working out whether the grid has a model — show a splash rather than
  /// flashing the choice screen and yanking it away a frame later.
  resolving,

  /// The grid has nothing to chat with yet and the user hasn't chosen a path, so
  /// show the choice screen (run local / use OpenAI / set up later).
  choose,

  /// Go into the app: the grid already serves a model, this computer is already
  /// a local host, or the user has already chosen a path.
  home,
}

/// Whether [overview] shows a real chat model being served *right now*: an online
/// node advertising at least one non-media model. Deliberately node-based, not
/// `/models`-based, so the relay's virtual `auto` routing model — which `/models`
/// lists even when no node is actually serving — never reads as "the grid has a
/// model" and sends a first user straight past setup into a chat that answers
/// nothing.
bool gridServesChatModel(GridOverview overview) {
  final onlineNodes = overview.nodes.where((node) => node.online).toList();
  if (onlineNodes.isEmpty) return false;
  if (onlineNodes.any(_nodeServesChat)) return true;
  // A node can be online without echoing its served model in its own record;
  // fall back to the grid's advertised chat models, still guarded by an online
  // node above so an empty grid with a stale model list doesn't count. The
  // virtual `auto` router is not a real model, so a lone `auto` here still reads
  // as empty. See [isRealChatModel].
  return overview.models.any((model) => isRealChatModel(model.id));
}

bool _nodeServesChat(OverviewNode node) {
  final advertised = [
    if ((node.model ?? '').isNotEmpty) node.model!,
    ...node.models,
  ];
  return advertised.any(isRealChatModel);
}

/// The route decision, as a pure function of everything it depends on, so the
/// whole fork is unit-tested without pumping async providers.
///
/// Cheap when the user has already chosen or is already a local host (the grid
/// [overview] is then irrelevant). Otherwise it asks whether the grid has a
/// model: a splash while that resolves, and — crucially — into the app on a relay
/// error rather than stranding the user at a fork, where the "no model yet" state
/// guides them.
OnboardingRoute routeFor({
  required OnboardingDecision? decision,
  required bool hasEngine,
  required bool hasLocalModel,
  required AsyncValue<GridOverview> overview,
}) {
  if (decision != null) return OnboardingRoute.home;
  // An established local host (engine installed + a model on disk) has, in
  // effect, already chosen "run local" — even if its engine isn't up this
  // second. Never park it at the choice screen; the shell resumes serving.
  if (hasEngine && hasLocalModel) return OnboardingRoute.home;
  return overview.when(
    data: (o) =>
        gridServesChatModel(o) ? OnboardingRoute.home : OnboardingRoute.choose,
    loading: () => OnboardingRoute.resolving,
    error: (_, _) => OnboardingRoute.home,
  );
}

/// The live route decision, wiring the app's providers into [routeFor].
final onboardingRouteProvider = Provider<OnboardingRoute>((ref) {
  final decision = ref.watch(onboardingDecisionProvider);
  final hasEngine = ref.watch(engineStatusProvider).llamaInstalled;
  final hasLocalModel = ref.watch(localModelsProvider).isNotEmpty;
  // Short-circuit before watching the relay: a user who already chose, or an
  // established local host, never needs the network check — so don't trigger it.
  if (decision != null || (hasEngine && hasLocalModel)) {
    return OnboardingRoute.home;
  }
  return routeFor(
    decision: decision,
    hasEngine: hasEngine,
    hasLocalModel: hasLocalModel,
    overview: ref.watch(gridOverviewProvider),
  );
});
