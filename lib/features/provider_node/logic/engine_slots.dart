/// Whether this computer can still take on an engine at all.
///
/// **One machine, one engine.** A computer shares a single engine with a grid,
/// whatever kind it is. The rule used to depend on the kind — the built-in
/// engine ran alone, hosted ones stacked — which left the page answering "can I
/// add one?" differently depending on which engine got there first, with a
/// separate refusal written into each card. One rule, in one sentence, instead.
///
/// Pure so the rule is unit-tested, rather than re-derived in a `build()`.
library;

import '../../../infrastructure/state/models/engine_run.dart';
import 'serving_engines_provider.dart';

/// Why this computer can't add an engine right now, or null when it can. Names
/// what's already sharing, so the way out — stop that one — is in the sentence
/// rather than left to the user to work out.
String? connectBlockedReason(List<ServingEngine> serving) {
  if (serving.isEmpty) return null;
  return 'This computer is already sharing ${_engineLabel(serving.first)}. It '
      'runs one engine at a time — stop it above to share a different one.';
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
