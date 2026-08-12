import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/logging/app_log.dart';
import '../../auth/logic/session_controller.dart';
import 'provider_run_controller.dart';
import 'throughput_probe.dart';

/// Where a warm-up for this machine's served model goes, and with what — or null
/// when nothing here is serving.
///
/// The **grid URL**, not the local engine: sending the "hi" through the relay is
/// what lets the *grid* time the answer (and populate the node's advertised
/// throughput), which is the whole point — the app isn't benchmarking, it's
/// asking the grid to. The relay routes it to whichever machine serves the
/// model, which is this one while it is serving.
final throughputWarmupTargetProvider =
    Provider<({String endpoint, String apiKey, String model})?>((ref) {
      final network = ref.watch(selectedNetworkProvider);
      final serving = ref.watch(servingModelProvider);
      if (network == null || serving == null || serving.isEmpty) return null;
      // The union joins several models with commas; a single engine serves one,
      // so the warm-up asks the first.
      final model = serving.split(',').first.trim();
      if (model.isEmpty) return null;
      return (
        endpoint: '${network.relayBaseUrl}/chat/completions',
        apiKey: network.relayApiKey,
        model: model,
      );
    });

/// This machine's measured decode rate for the model it is serving, or null
/// until a warm-up has answered.
///
/// The relay advertises a node's throughput, but not until it has served a real
/// request — so a machine that just started serving shows a blank "— tok/s"
/// until someone happens to use it. This closes that gap by *being* that first
/// request: the moment this machine is serving, the app sends one "hi" through
/// the grid to its model, and the grid times it. The card shows the number
/// straight away, and once the relay's own overview catches up its figure takes
/// over (the card prefers it — see `_ThroughputForNode`).
///
/// Measured once per `(endpoint, model)`: a warm-up is a small cost, and it
/// resets when serving stops or the model changes, so the card never shows the
/// last model's speed against this one.
final localThroughputProvider = NotifierProvider<LocalThroughput, double?>(
  LocalThroughput.new,
);

class LocalThroughput extends Notifier<double?> {
  /// The `endpoint|model` the current value was measured for, so a rebuild that
  /// leaves both unchanged keeps the number instead of re-probing.
  String? _measuredFor;

  @override
  double? build() {
    final target = ref.watch(throughputWarmupTargetProvider);
    if (target == null) {
      _measuredFor = null;
      return null;
    }
    final key = '${target.endpoint}|${target.model}';
    if (key == _measuredFor) return state;

    _measuredFor = key;
    // The probe is async and this runs during build, so it is fired after the
    // frame rather than awaited — the card shows the blank until the number
    // lands, then updates.
    Future.microtask(() => _measure(target, key));
    return null;
  }

  Future<void> _measure(
    ({String endpoint, String apiKey, String model}) target,
    String key,
  ) async {
    final tokS = await ref
        .read(throughputProbeProvider)
        .measure(
          endpoint: target.endpoint,
          apiKey: target.apiKey,
          model: target.model,
        );
    // Serving may have changed while the warm-up was out; only the current one's
    // answer is worth keeping.
    if (!ref.mounted || _measuredFor != key) return;
    state = tokS;
    if (tokS != null) {
      ref
          .read(appLogProvider)
          .info(
            'engine',
            'Grid measured ${target.model} at ${tokS.round()} tok/s',
          );
    }
  }
}
