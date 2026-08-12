import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/logging/app_log.dart';
import 'provider_run_controller.dart';
import 'throughput_probe.dart';

/// This machine's measured decode rate for the model it is serving, or null
/// until a warm-up has answered.
///
/// The relay eventually advertises a node's throughput, but not until it has
/// served a real request — so a machine that just started serving shows a blank
/// "— tok/s" until someone happens to use it. This fills that gap: the moment a
/// local engine is up, the app sends it one "hi" and reads back the rate, so the
/// card has a number to show straight away.
///
/// Measured once per `(endpoint, model)`: a warm-up is a small cost, and re-running
/// it on every rebuild would tie up the engine the user is about to chat with.
/// It resets to null when serving stops or the model changes, so the card never
/// shows last model's speed against this one.
final localThroughputProvider = NotifierProvider<LocalThroughput, double?>(
  LocalThroughput.new,
);

class LocalThroughput extends Notifier<double?> {
  /// The `endpoint|model` the current value was measured for, so a rebuild that
  /// leaves both unchanged keeps the number instead of re-probing.
  String? _measuredFor;

  @override
  double? build() {
    final endpoint = ref.watch(localProviderEndpointProvider);
    final serving = ref.watch(servingModelProvider);
    if (endpoint == null || serving == null || serving.isEmpty) {
      _measuredFor = null;
      return null;
    }
    // The union joins several models with commas; a single engine serves one, so
    // the warm-up asks the first — which is the served gguf for the built-in
    // engine this endpoint belongs to.
    final model = serving.split(',').first.trim();
    final key = '$endpoint|$model';
    if (key == _measuredFor) return state;

    _measuredFor = key;
    // The probe is async and this runs during build, so it is fired after the
    // frame rather than awaited — the card shows the blank until the number
    // lands, then updates.
    Future.microtask(() => _measure(endpoint, model, key));
    return null;
  }

  Future<void> _measure(String endpoint, String model, String key) async {
    final tokS = await ref
        .read(throughputProbeProvider)
        .measure(endpoint: endpoint, model: model);
    // Serving may have changed while the warm-up was out; only the current one's
    // answer is worth keeping.
    if (!ref.mounted || _measuredFor != key) return;
    state = tokS;
    if (tokS != null) {
      ref
          .read(appLogProvider)
          .info('engine', 'Measured $model at ${tokS.round()} tok/s');
    }
  }
}
