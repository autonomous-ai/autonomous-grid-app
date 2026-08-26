/// Slider floor: below 4k a model can barely hold a conversation, so this is
/// the smallest context length offered.
const minContextTokens = 4096;

/// Granularity the slider snaps to — 1k (1024 tokens) — so a dragged value is
/// always a clean "…k" the user can read back (e.g. 200k), never an odd number.
const _contextStep = 1024;

/// Preferred default when the user hasn't chosen a context length: 200k, or the
/// model's maximum when it supports less. Balances how much of the chat the
/// model keeps in mind against the memory a large context costs.
const _defaultContextTarget = 200 * _contextStep; // 204800 → labelled "200k"

/// The default context length for a model whose maximum is [maxContext].
int defaultContextLength(int maxContext) =>
    maxContext < _defaultContextTarget ? maxContext : _defaultContextTarget;

/// Snap a raw token count (mid-drag) to the nearest 1k, kept within
/// [minContextTokens]…[maxContext]. Lets the slider drag smoothly while every
/// reported value lands on a clean 1k step, including any value between the
/// old power-of-two stops (e.g. 200k, which sits between 128k and 256k).
int snapContextLength(int tokens, int maxContext) {
  final snapped = (tokens / _contextStep).round() * _contextStep;
  return snapped.clamp(minContextTokens, maxContext);
}

/// Human label for a context length in tokens: 4096 → "4k", 204800 → "200k",
/// 262144 → "256k". Rounds to the nearest "k" (1024 tokens) so odd maxima
/// (40960 → "40k") stay tidy.
///
/// A megabyte-scale window switches unit rather than reading "1024k", which is
/// a number people have to convert in their heads to compare against the "1M"
/// their own engine's flags are written in.
String formatContextLength(int tokens) {
  const perM = 1024 * 1024;
  if (tokens < perM) return '${(tokens / 1024).round()}k';
  final millions = tokens / perM;
  // One decimal only where it says something: 1.5M is worth reading, 1.0M is
  // just a longer way to write 1M.
  final label = millions == millions.roundToDouble()
      ? '${millions.round()}'
      : millions.toStringAsFixed(1);
  return '${label}M';
}
