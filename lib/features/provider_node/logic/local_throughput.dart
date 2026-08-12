import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/logging/app_log.dart';
import '../../auth/logic/session_controller.dart';
import '../../models/logic/advertise_name.dart';
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
      final file = serving.split(',').first.trim();
      if (file.isEmpty) return null;
      return (
        endpoint: '${network.relayBaseUrl}/chat/completions',
        apiKey: network.relayApiKey,
        // A local engine's entry is the gguf **filename**; the grid advertises
        // the name `--advertise-as` derived from it. Sending the filename asks
        // the relay for a model it has never heard of, which fails as quietly as
        // a machine that is simply slow.
        model: deriveAdvertiseName(file),
      );
    });

/// This machine's measured decode rate for the model it is serving, or null
/// until a warm-up has answered with a rate it measured itself.
///
/// The relay advertises a node's throughput, but not until it has served a real
/// request — so a machine that just started serving shows a blank "— tok/s"
/// until someone happens to use it. This closes that gap by *being* that first
/// request: the moment this machine is serving, the app sends one "hi" through
/// the grid to its model, and the grid times it. Once the relay's own overview
/// catches up its figure takes over (the card prefers it — see
/// `_ThroughputForNode`).
///
/// A [FutureProvider] rather than a notifier firing a request from `build()`:
/// the probe *is* this provider's value, so Riverpod runs it once per
/// `(endpoint, model)` — the target is a record, compared by value — re-runs it
/// when serving changes, and drops it when nothing is serving. The probe never
/// throws (it answers null), so there is no failure for Riverpod 3 to retry.
final localThroughputProvider = FutureProvider<double?>((ref) async {
  final target = ref.watch(throughputWarmupTargetProvider);
  if (target == null) return null;
  final tokS = await ref
      .read(throughputProbeProvider)
      .measure(
        endpoint: target.endpoint,
        apiKey: target.apiKey,
        model: target.model,
      );
  if (tokS == null) return null;
  ref
      .read(appLogProvider)
      .info('engine', 'Grid measured ${target.model} at ${tokS.round()} tok/s');
  return tokS;
});
