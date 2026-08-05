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
/// This is the app's only source for the figure. The relay advertises none —
/// `/v1/models` has no such field and `/grid/overview` returns
/// `context_length: null` for every model (`TODO(BE)`) — so a window is either
/// learned here or unknown, and an unknown one is left unset rather than
/// guessed: a guess too low compacts a chat that had room, and one too high
/// fails exactly the way this exists to prevent.
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

/// The window to run [model] against, or null while nothing is known about it.
///
/// Two sources, smaller wins. The grid's own answer comes first in principle —
/// it is the one that needs no failure to arrive — but today it is always null,
/// so in practice this reads what an engine taught the app. Smaller rather than
/// newer because one model id can be served by several machines (the office qwen
/// is served by two) and only the smallest window is safe for all of them.
final modelContextWindowProvider = Provider.autoDispose.family<int?, String>((
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
  if (known.isEmpty) return null;
  return known.reduce((a, b) => a < b ? a : b);
});
