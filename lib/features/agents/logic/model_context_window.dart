import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/model_context_store.dart';
import '../../network/logic/grid_overview_provider.dart';

/// The wordings an engine refuses an over-long turn in, each with the window it
/// actually has in group 1.
///
/// Two dialects, because a grid is whatever its providers run: the one this was
/// written against — `request (98013 tokens) exceeds the available context size
/// (96000 tokens), try increasing it` — and vLLM's, which says the same thing
/// the other way round. llama.cpp's own wording carries no number at all, which
/// is why [isContextOverflow] is a separate question from this one.
final _windowPatterns = [
  RegExp(
    r'available context size\s*\(\s*(\d+)\s*tokens?',
    caseSensitive: false,
  ),
  RegExp(r'maximum context length is\s*(\d+)\s*tokens?', caseSensitive: false),
];

/// Whether [raw] is an engine turning a turn away for being longer than it can
/// hold — as opposed to any of the other things an agent can fail on.
bool isContextOverflow(String raw) {
  final lower = raw.toLowerCase();
  return lower.contains('available context size') ||
      lower.contains('maximum context length');
}

/// The context window an engine reported when it refused a turn, or null when
/// the refusal named no number.
///
/// The most reliable of the three sources, because it is the machine that is
/// actually serving saying what it actually has. The relay now carries the
/// figure too, but sparsely: measured 2026-08-06 on the office grid,
/// `/grid/overview` gives `context_length: 128000` for one model of three and
/// `null` for the rest, and `/v1/models` has grown a `context_window` field that
/// is null on every model so far (`TODO(BE)`). What neither source covers falls
/// back on [kAssumedContextWindow].
int? contextWindowFromError(String raw) {
  for (final pattern in _windowPatterns) {
    final match = pattern.firstMatch(raw);
    final tokens = int.tryParse(match?.group(1) ?? '');
    if (tokens != null && tokens > 0) return tokens;
  }
  return null;
}

/// The share of an engine's window an agent may fill before it has to summarize.
///
/// Not the whole thing: the engine counts the reply against the same window, and
/// an agent that waits until it is full has already sent the request that gets
/// refused. Four fifths of the 96k window this was written against leaves ~19k
/// for the answer and for the agent overshooting its own estimate — the turn
/// that failed went 2k past.
const int _ceilingNumerator = 4;
const int _ceilingDenominator = 5;

/// What to hand an agent as its own ceiling, given the [engineWindow] the model
/// really has. See [_ceilingNumerator].
int agentContextCeiling(int engineWindow) =>
    engineWindow * _ceilingNumerator ~/ _ceilingDenominator;

/// What to run a model against when no source has named its window.
///
/// The three sources can all be missing at once: the grid advertises a figure
/// for some models and `null` for the rest, and an engine only names its window
/// by refusing a turn, which has not happened yet on a model nobody has pushed.
/// Leaving it unset there sounds like the humble choice and isn't — it hands the
/// decision to Claude Code, which sizes its window from the model it *thinks* it
/// is talking to (Anthropic's, 200k and up). So "no ceiling" was in practice a
/// 200k guess made by the component with the least information.
///
/// 32k instead, and deliberately low, because the two ways to be wrong are not
/// symmetric. Too high and the turn dies at the engine: the user loses the
/// answer and the session, and llama.cpp's own refusal carries no number for the
/// app to learn from (see [_windowPatterns]), so it can happen again on the next
/// long chat. Too low and the conversation summarizes earlier than it had to —
/// it costs fidelity and nothing else. Any model a real figure exists for never
/// comes near this number.
const int kAssumedContextWindow = 32768;

/// The window to run [model] against: what the grid advertises, what an engine
/// taught, or [kAssumedContextWindow] when neither has said anything.
///
/// Between the two real sources the smaller wins — not the newer — because one
/// model id can be served by several machines (the office qwen is served by two)
/// and only the smallest window is safe for all of them. The assumption is not
/// in that comparison: it is what's left when there is nothing to compare.
final modelContextWindowProvider = Provider.autoDispose.family<int, String>((
  ref,
  model,
) {
  final key = normalizeModelKey(model);
  final advertised = [
    for (final served in ref.watch(gridModelsProvider))
      if (normalizeModelKey(served.id) == key)
        if (served.contextLength case final int tokens when tokens > 0) tokens,
  ];
  final known = [...advertised, ?ref.watch(learnedModelContextProvider)[key]];
  if (known.isEmpty) return kAssumedContextWindow;
  return known.reduce((a, b) => a < b ? a : b);
});
