/// The edges of a word, for the patterns that have to hold in Vietnamese too.
///
/// `\b` is the usual way to say "the whole word, not a piece of one", and it
/// counts `[A-Za-z0-9_]` as word characters and nothing else. So it never holds
/// beside a word ending in a letter outside that set — which is every accented
/// vowel this app's own users type. A unit ending in one could not be matched
/// at all, while its neighbour ending in a plain consonant matched fine.
///
/// Two readings were wrong because of it, both on 2026-08-20: an hourly repeat
/// read as naming no gap at all, and an hourly task lost its cadence on the way
/// to the scheduler and became a once-a-day one. Both patterns were asking for
/// the hour, and the word for it ends in an accented vowel.
///
/// A pattern using these must be built with `unicode: true` — `\p{L}` is a
/// property escape only under that flag, and two literal characters without it.
library;

/// What may not sit before a word, so a match covers the whole of it.
const String kBeforeWord = r'(?<![\p{L}\p{N}])';

/// What may not sit after a word — `\b`'s other half. See the library note for
/// why this is not `\b`, and for the `unicode: true` a pattern using it needs.
const String kAfterWord = r'(?![\p{L}\p{N}])';
