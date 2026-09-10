/// The one place a count is joined to the thing it counts.
///
/// It lived in `features/network/logic/grid_power_provider.dart`, where the pill
/// and its panels could reach it and nothing else could without importing
/// another feature's internals (§1). Everything else therefore wrote its own —
/// a private `_plural`, a `_stepCount`, and a `count == 1 ? 'chat' : 'chats'`
/// ternary in a dozen files — and the places that wrote none shipped "1
/// members", "1 requests" and "1 tokens" to users.
library;

/// Pluralises a unit against its count: `1 node`, `3 nodes`, `0 nodes`.
///
/// **Zero takes the plural**, which is the English rule and not an oversight:
/// "0 nodes" is right and "0 node" is not.
///
/// [plural] is for the words an `s` doesn't fix — `plural(2, 'entry',
/// 'entries')`. Pass it whenever the word is irregular even if the count can
/// only be one today; the count is the part that changes.
///
/// This joins the *word*, never the number: callers keep their own formatting
/// (`formatCount`, a raw `$n`) and read this for the noun beside it. A version
/// that returned "3 nodes" whole would have to guess which of the two the caller
/// wanted, and every compact figure on the grid pill ("1.2M") wants only one.
String plural(int count, String singular, [String? plural]) =>
    count == 1 ? singular : (plural ?? '${singular}s');
