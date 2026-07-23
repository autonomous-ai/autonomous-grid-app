import 'chat_message.dart';

/// How much of the model's context window one conversation is occupying.
///
/// The number behind the composer's context ring. [usedTokens] is what the whole
/// conversation costs to send *now* — every turn plus the system head, not just
/// the last message — because that is what runs out. [limitTokens] is the window
/// it has to fit in, and is **null when nobody said**: not every grid publishes
/// its models' context length, and a ring filled against a guessed denominator
/// would be a number the user can't act on.
class ContextUsage {
  const ContextUsage({
    required this.usedTokens,
    this.limitTokens,
    this.estimated = false,
  });

  final int usedTokens;

  /// The model's context window, or null while nothing on the wire has said how
  /// big it is.
  final int? limitTokens;

  /// True when [usedTokens] was counted here rather than reported by the model
  /// itself — close enough to steer by, but not the model's own tokenizer, so
  /// anything showing it says "about".
  final bool estimated;

  /// The 0–1 share of the window in use, or null while the window is unknown.
  /// Clamped, because a model that compacts its own history can report more
  /// tokens than the window it compacted them into.
  double? get fraction {
    final limit = limitTokens;
    if (limit == null || limit <= 0) return null;
    return (usedTokens / limit).clamp(0.0, 1.0);
  }

  /// Whole percent of the window in use, or null while it's unknown.
  int? get percentUsed {
    final share = fraction;
    return share == null ? null : (share * 100).round();
  }

  /// The same usage with [limit] filled in — for a reporter (a relay's `usage`
  /// block, Codex) that counts tokens but never says how big the window is.
  /// Never overwrites a window the reporter did give.
  ContextUsage withLimit(int? limit) => limitTokens != null || limit == null
      ? this
      : ContextUsage(
          usedTokens: usedTokens,
          limitTokens: limit,
          estimated: estimated,
        );
}

/// Roughly how many tokens [text] costs.
///
/// The fallback for an agent that reports no usage of its own. Deliberately not
/// one-size-fits-all `chars / 4`: that rule is an English-ASCII rule, and this
/// app's users write Vietnamese, where the accented letters each cost far more
/// than a quarter token. Splitting the count by script keeps a Vietnamese chat
/// from reading as a third as full as it really is.
int estimateTokens(String text) {
  if (text.isEmpty) return 0;
  var ascii = 0;
  var wide = 0;
  for (final rune in text.runes) {
    if (rune < 128) {
      ascii++;
      continue;
    }
    wide++;
  }
  final tokens = ascii / 4 + wide / 1.5;
  return tokens < 1 ? 1 : tokens.round();
}

/// What one message costs on top of its text — the role framing every chat
/// dialect wraps a turn in.
const int _turnOverheadTokens = 4;

/// What the assistant's standing instructions cost, before a word is typed.
/// A flat figure: the system head differs per agent, and this estimate exists
/// precisely for the agents that tell us nothing.
const int _systemHeadTokens = 40;

/// Roughly how many tokens the whole conversation costs to send now — the
/// fallback used until (or unless) the model reports its own count.
int estimateConversationTokens(List<ChatMessage> messages) {
  if (messages.isEmpty) return 0;
  var total = _systemHeadTokens;
  for (final message in messages) {
    total += estimateTokens(message.text) + _turnOverheadTokens;
  }
  return total;
}

/// A token count at a glance: `840`, `62k`, `1.2M`. Short because it sits in a
/// tooltip beside a second one, where `258000` and `62000` are two long numbers
/// the eye has to line up digit by digit.
String formatTokenCount(int tokens) {
  if (tokens < 1000) return '$tokens';
  if (tokens < 1000000) {
    final thousands = tokens / 1000;
    return thousands < 10
        ? '${_trimZero(thousands.toStringAsFixed(1))}k'
        : '${thousands.round()}k';
  }
  return '${_trimZero((tokens / 1000000).toStringAsFixed(1))}M';
}

/// `1.0` reads as a number someone measured; `1` reads as the size it is.
String _trimZero(String value) =>
    value.endsWith('.0') ? value.substring(0, value.length - 2) : value;
