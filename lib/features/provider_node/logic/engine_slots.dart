/// What this computer can still take on: which add-engine forms may start
/// another engine, and which would only produce a duplicate.
///
/// Two rules, and they differ because the constraint differs. An engine that
/// **runs here** — the built-in one, or a server the user runs on this machine
/// that Grid points at — competes for the same GPU and memory, so the machine
/// serves one at a time. A **hosted** engine costs this computer nothing, so any
/// number can stack; what it can't do is offer the grid a model it is already
/// serving, which would advertise the same name twice.
///
/// Pure so the rule is unit-tested, rather than re-derived in each block's
/// `build()` — three widgets ask the same question.
library;

import '../../../infrastructure/state/models/engine_run.dart';
import 'serving_engines_provider.dart';

/// Whether [engine] runs on this computer (built-in, or a server here that Grid
/// points at) rather than in a vendor's cloud.
bool runsOnThisComputer(ServingEngine engine) =>
    engine.kind == EngineKind.local || engine.kind == EngineKind.external;

/// The engine already running on this computer, or null when none is — the one
/// that has to stop before another can start.
ServingEngine? onDeviceEngine(List<ServingEngine> serving) {
  for (final engine in serving) {
    if (runsOnThisComputer(engine)) return engine;
  }
  return null;
}

/// Why this computer can't take another engine of its own right now, or null
/// when it can. Names what's already sharing, so the way out — stop that one —
/// is in the sentence rather than left to the user to work out.
String? connectBlockedReason(List<ServingEngine> serving) {
  final engine = onDeviceEngine(serving);
  if (engine == null) return null;
  return 'This computer is already sharing ${_engineLabel(engine)}. It runs '
      'one engine at a time — stop it above to share a different one.';
}

/// The advertised model names this machine already serves through hosted
/// providers, so a cloud block can't offer to share the same one twice.
Set<String> apiModelsServed(List<ServingEngine> serving) => {
  for (final engine in serving)
    if (engine.kind == EngineKind.api) ...engine.models,
};

/// What to call the engine in a sentence: the model it serves, else the server
/// it points at, else a plain fallback so the copy never reads "sharing .".
String _engineLabel(ServingEngine engine) {
  if (engine.models.isNotEmpty) return engine.models.first;
  final endpoint = engine.endpointUrl;
  if (endpoint != null && endpoint.isNotEmpty) {
    return endpoint.replaceFirst(RegExp(r'^https?://'), '');
  }
  return 'a model';
}
