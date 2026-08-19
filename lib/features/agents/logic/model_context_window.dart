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

/// How many tokens to hold back for the model's own reply.
///
/// The engine counts the reply against the same window as the prompt, so a turn
/// is refused when `input + output` crosses the line — not when the input alone
/// does. Claude Code otherwise asks for 32000 output tokens on every request
/// (its default for a Claude-class model), and on a grid model that number is
/// the whole bug: a session at 230145 input tokens on a 262144 window is *under*
/// the window on its own, and only the `+32000` reserved for the reply pushed
/// the total to 262145 and drew the 400 (autonomous-grid-app#47). Handed to
/// Claude Code as `CLAUDE_CODE_MAX_OUTPUT_TOKENS` (see `claudeCodeEnv`), this
/// caps that reservation to a figure the window can actually spare.
///
/// 8192 rather than more because it has to fit inside the room
/// [agentContextCeiling] leaves above the ceiling on *every* window the app runs
/// against, down to [kAssumedContextWindow] (65536): a reserve larger than that
/// room would let a freshly compacted session overflow on its very next reply —
/// the failure this is fixing, not a new one to introduce. 8192 tokens is a long
/// reply on its own, and an agentic turn that needs more continues across
/// requests rather than losing the work.
const int kAgentReplyReserveTokens = 8192;

/// The share of an engine's window an agent may fill before it has to summarize.
///
/// Not the whole thing: the engine counts the reply against the same window (see
/// [kAgentReplyReserveTokens]), so an agent that waits until the window is full
/// has already sent the request that gets refused. Four fifths is the headroom
/// on a roomy window — ~52k on the office 262k model, absorbing both the reply
/// and a turn overshooting its own estimate.
const int _ceilingNumerator = 4;
const int _ceilingDenominator = 5;

/// What to hand an agent as its own ceiling, given the [engineWindow] the model
/// really has.
///
/// Four fifths of a roomy window, but never so high that the room left above it
/// can't hold a reply: a fifth of 65536 is 13107, barely over the reserve, and a
/// fifth of a 32k model is *under* it — so on a tight window the ceiling reserves
/// the reply plus a margin for mid-turn growth outright, taking whichever of the
/// two is lower. Floored at half the window so a window too small for the reserve
/// still yields a usable figure rather than a negative one; no model the app runs
/// against is that small (see [kAssumedContextWindow]).
int agentContextCeiling(int engineWindow) {
  final proportional = engineWindow * _ceilingNumerator ~/ _ceilingDenominator;
  // The reply, plus the same again for a turn that grows past the ceiling before
  // the next between-turn check can catch it (see [needsCompaction]).
  final reserved = engineWindow - kAgentReplyReserveTokens * 2;
  final ceiling = proportional < reserved ? proportional : reserved;
  final floor = engineWindow ~/ 2;
  return ceiling > floor ? ceiling : floor;
}

/// Whether a turn resuming a session that has already filled [usedTokens] of
/// [engineWindow] must summarize before it sends.
///
/// The same ceiling the agent is handed, asked a second time — deliberately one
/// number and not two, so the app's own check can't drift from what it told the
/// agent to do.
///
/// Asking at all is the point, and the reason is now measured rather than
/// suspected. Claude Code is given that ceiling as
/// `CLAUDE_CODE_AUTO_COMPACT_WINDOW` and did not act on it: measured on a grid
/// model advertising 200000 (ceiling 160000), a session was refused by the
/// engine at 230145 input tokens.
///
/// The mechanism, read out of the 2.1.234 binary on 2026-08-19: the variable is
/// floored at 100000 and then compaction fires at
/// `window − min(maxOutputTokens, 20000) − 13000`, so a ceiling below that floor
/// never reaches the runtime at all (see [kClaudeCompactWindowFloor]). On every
/// window the app has to assume, **this check has been the only thing enforcing
/// the ceiling.** Removing it would leave nothing.
///
/// Zero means no turn has reported a figure yet — the session is as empty as it
/// will ever be, so there is nothing to make room for.
bool needsCompaction({required int usedTokens, required int engineWindow}) =>
    usedTokens > 0 && usedTokens >= agentContextCeiling(engineWindow);

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
/// 64k instead — under every figure this grid has actually produced (128000
/// advertised for one model, 96000 learned from another's refusal), and above
/// what an engine left on a default is likely to hold. It errs low on purpose,
/// because the two ways to be wrong are not symmetric. Too high and the turn
/// dies at the engine: the user loses the answer and the session, and
/// llama.cpp's own refusal carries no number for the app to learn from (see
/// [_windowPatterns]), so it can happen again on the next long chat. Too low and
/// the conversation summarizes earlier than it had to — it costs fidelity and
/// nothing else. Any model a real figure exists for never comes near this
/// number.
const int kAssumedContextWindow = 65536;

/// The window to run [model] against: what the grid advertises, what an engine
/// taught, or [kAssumedContextWindow] when neither has said anything.
///
/// Between the two real sources the smaller wins — not the newer — because one
/// model id can be served by several machines (the office qwen is served by two)
/// and only the smallest window is safe for all of them. The assumption is not
/// in that comparison: it is what's left when there is nothing to compare.
final modelContextWindowProvider = Provider.autoDispose.family<int, String>(
  (ref, model) =>
      ref.watch(knownModelContextWindowProvider(model)) ??
      kAssumedContextWindow,
);

/// The window for [model] **only when something real has named it** — null where
/// [modelContextWindowProvider] would substitute [kAssumedContextWindow].
///
/// The same two sources, smaller wins, minus the assumption. Separate because
/// the assumption is safe for one caller and wrong for the others, and an `int`
/// cannot tell them apart: once the guess is folded in, every reader downstream
/// believes a number was reported.
///
/// Claude Code is the caller the guess suits — its own fallback is Anthropic's
/// 200k-and-up, so guessing low there is strictly safer than staying quiet (see
/// [kAssumedContextWindow]). Any caller *configuring another agent* wants this
/// one instead: telling Codex a grid model holds 65536 when it holds 262144
/// makes it summarize four times too often, which is the thrash direction — and
/// on a model that really is small, saying nothing leaves the agent on its own
/// default rather than on a figure this app invented.
final knownModelContextWindowProvider = Provider.autoDispose
    .family<int?, String>((ref, model) {
      final key = normalizeModelKey(model);
      final advertised = [
        for (final served in ref.watch(gridModelsProvider))
          if (normalizeModelKey(served.id) == key)
            if (served.contextLength case final int tokens when tokens > 0)
              tokens,
      ];
      final known = [
        ...advertised,
        ?ref.watch(learnedModelContextProvider)[key],
      ];
      if (known.isEmpty) return null;
      return known.reduce((a, b) => a < b ? a : b);
    });
