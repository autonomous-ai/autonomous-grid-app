import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/providers.dart';
import '../../../infrastructure/state/models/engine_run.dart';
import '../../auth/logic/session_controller.dart';
import 'engine_liveness.dart';

/// One engine this machine is serving on the active grid, ready for the list UI
/// — a flattened view of an [EngineSpec] plus the selector that stops just it.
class ServingEngine {
  const ServingEngine({
    required this.kind,
    required this.models,
    required this.apiKind,
    required this.endpointUrl,
    required this.leaveSelector,
  });

  final EngineKind kind;
  final List<String> models;
  final String? apiKind;
  final String? endpointUrl;

  /// What `grid leave --engine <selector>` matches to drop this one. Null when
  /// the engine carries nothing to match on — its row then offers Stop-all only.
  final String? leaveSelector;

  factory ServingEngine.fromSpec(EngineSpec spec) => ServingEngine(
    kind: spec.kind,
    models: spec.models,
    apiKind: spec.apiKind,
    endpointUrl: spec.endpointUrl,
    leaveSelector: spec.leaveSelector,
  );
}

/// Bumped after any join or leave so the union re-reads from disk. The store is
/// a plain reader, not a listenable, so the run controller ticks this whenever
/// it changes the roster (see `ProviderRunController`).
final engineUnionRefreshProvider = NotifierProvider<EngineUnionRefresh, int>(
  EngineUnionRefresh.new,
);

/// A monotonic tick the run controller bumps to invalidate [servingEnginesProvider].
class EngineUnionRefresh extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state = state + 1;
}

/// The engines this machine is serving on the active grid — its live union read
/// from `remote.json` (ADR 0010). Empty when nothing is serving. Re-reads when
/// the grid changes or [engineUnionRefreshProvider] ticks.
final servingEnginesProvider = Provider<List<ServingEngine>>((ref) {
  ref.watch(engineUnionRefreshProvider);
  final network = ref.watch(selectedNetworkProvider);
  if (network == null) return const [];
  final store = ref.read(gridHomeStoreProvider);
  final record = firstLiveRun(store.listEngineRuns(network.networkId));
  if (record == null) return const [];
  return [
    for (final spec in record.engines)
      if (spec.models.isNotEmpty || spec.endpointUrl != null)
        ServingEngine.fromSpec(spec),
  ];
});
