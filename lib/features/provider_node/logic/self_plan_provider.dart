import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/grid_overview.dart';
import '../../network/logic/grid_overview_provider.dart';
import '../../network/logic/node_display.dart';
import 'provider_run_controller.dart';

/// This machine's own node in the active grid's overview: the one whose name
/// matches the [nodeNameProvider] we join under (`grid join --name`, see
/// [ProviderRunController]). Null until the overview lands, or when this machine
/// isn't hosting on the selected grid.
///
/// Reads the overview through [gridOverviewSnapshot] — the same one-door rule the
/// rest of the derived graph follows — so a poll in flight never blanks it.
final selfOverviewNodeProvider = Provider<OverviewNode?>((ref) {
  final name = ref.watch(nodeNameProvider).trim();
  final nodes =
      ref.watch(gridOverviewSnapshot)?.nodes ?? const <OverviewNode>[];
  for (final node in nodes) {
    if (node.name.trim() == name) return node;
  }
  return null;
});

/// The subscription plan label for *this* machine's own node — "Pro plan",
/// "Plus plan", "Free plan" — when it joined the grid with a codex/ChatGPT
/// subscription seat (ADR 0015). Null when this machine isn't hosting, or hosts
/// with hardware rather than a subscription (a plain node carries no plan).
///
/// Drives the top bar's plan pill: the plan is the user's own entitlement, so it
/// belongs beside the grid's summary, not only buried in the per-node list.
final selfPlanLabelProvider = Provider<String?>((ref) {
  final node = ref.watch(selfOverviewNodeProvider);
  return node == null ? null : nodePlanLabel(node);
});
