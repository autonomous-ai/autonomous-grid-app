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

/// Whether this computer has a free slot for another engine.
///
/// A predicate, not a sentence: the page acts on it by simply not offering the
/// add-engine cards while something is serving. It used to return the refusal
/// as copy, which put a paragraph under the serving card explaining a rule the
/// user had already met — the Stop button in that card is the way out, and it
/// is right there.
bool canAddEngine(List<ServingEngine> serving) => serving.isEmpty;

/// The advertised model names this machine already serves through hosted
/// providers, so a cloud block can't offer to share the same one twice.
Set<String> apiModelsServed(List<ServingEngine> serving) => {
  for (final engine in serving)
    if (engine.kind == EngineKind.api) ...engine.models,
};
