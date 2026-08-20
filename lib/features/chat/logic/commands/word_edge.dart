/// The edges of a word, for the patterns that have to hold in Vietnamese too.
///
/// `\b` is the usual way to say "the whole word, not a piece of one", and it
/// counts `[A-Za-z0-9_]` as word characters and nothing else. So it never held
/// beside a word ending in a Vietnamese letter: `(giờ|phút)\b` matched "phút"
/// on its `t` and could not match "giờ" at all — and "mỗi giờ" is the plainest
/// way to say the commonest gap there is.
///
/// Two readings were wrong because of it, both on 2026-08-20: "lặp lại mỗi giờ
/// …" was offered instead of started, because the gap read as unnamed; and a
/// task said as "mỗi 2 giờ" lost its cadence on the way to the scheduler and
/// became a once-a-day one.
///
/// A pattern using these must be built with `unicode: true` — `\p{L}` is a
/// property escape only under that flag, and two literal characters without it.
library;

/// What may not sit before a word, so a match covers the whole of it.
const String kBeforeWord = r'(?<![\p{L}\p{N}])';

/// What may not sit after a word — `\b`'s other half. See the library note for
/// why this is not `\b`, and for the `unicode: true` a pattern using it needs.
const String kAfterWord = r'(?![\p{L}\p{N}])';
