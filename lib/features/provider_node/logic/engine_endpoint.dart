/// What the app makes of the address someone typed for their own engine.
///
/// Three outcomes rather than a string plus a flag, so a caller cannot forget
/// to check: a form that reads [EngineAddressReady.base] has already been told
/// the address is usable.
sealed class EngineAddress {
  const EngineAddress();
}

/// Nothing typed yet. Not an error — a blank field is where everyone starts, and
/// showing red before the first keystroke reads as the app being broken.
class EngineAddressEmpty extends EngineAddress {
  const EngineAddressEmpty();
}

/// The address is usable. [base] is what gets joined with **and** probed —
/// never two different strings (see [readEngineAddress]).
class EngineAddressReady extends EngineAddress {
  const EngineAddressReady(this.base);

  final String base;

  /// Where to ask what this server serves. The one URL the app calls before
  /// committing to a join.
  String get modelsUrl => '$base/models';

  /// The URL the engine will be asked to answer on once it has joined.
  ///
  /// Shown back under the field, because it is the line a person can compare
  /// against the `curl` in their own server's documentation — which is where a
  /// missing `/v1` becomes obvious and nowhere else does.
  String get chatUrl => '$base/chat/completions';
}

/// The address can't be used. [message] is the line to put under the field —
/// already written for a person, not a log.
class EngineAddressRejected extends EngineAddress {
  const EngineAddressRejected(this.message);

  final String message;
}

/// The endpoint suffixes people paste in by mistake, **longest first**.
///
/// Order is load-bearing: `/chat/completions` also ends with `/completions`, so
/// checking the short one first would turn `…/v1/chat/completions` into
/// `…/v1/chat` — an address that looks plausible and answers nothing.
const List<String> _openAiPaths = [
  '/chat/completions',
  '/embeddings',
  '/completions',
  '/responses',
];

/// Read what the user typed and decide what the app will call.
///
/// The rule is deliberately small: trim, drop trailing slashes, cut one OpenAI
/// endpoint suffix if it is there, and stop. **It never adds anything** — not
/// `/v1`, not a scheme, not a guess.
///
/// That restraint is the point. The tempting version tries `<url>/models` and
/// `<url>/v1/models` and keeps whichever answers, which quietly breaks the one
/// invariant worth having here: **what gets tested is what gets called.** An
/// address missing `/v1` would pass its check against a URL the join never uses,
/// and the join would then fail exactly as it does today — only now wearing a
/// green tick. A grid node registered that way answers every request with
/// `engine error 404: {"detail":"Not Found"}`, and because the capability probe
/// travels the same wrong URL it also registers the model as supporting nothing
/// at all, so chat is refused before a request is even made
/// (`1_docs/bubu/BUG-GBX03073-3-REQUEST-FAILED-404.md`).
///
/// So a missing `/v1` is not repaired here. It fails at [EngineAddressReady
/// .modelsUrl] the moment Start is pressed, and the person fixes their own
/// address — which is the only place the truth lives.
EngineAddress readEngineAddress(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return const EngineAddressEmpty();
  if (!_hasWebScheme(trimmed)) {
    return const EngineAddressRejected(
      'Start the address with http:// or https://',
    );
  }
  // A query or fragment cannot survive having `/models` stapled on, and it is
  // always a paste that took too much with it.
  if (trimmed.contains('?') || trimmed.contains('#')) {
    return const EngineAddressRejected(
      'Remove everything from the ? onwards — Grid needs the address only.',
    );
  }
  final base = _withoutEndpointPath(_withoutTrailingSlashes(trimmed));
  final uri = Uri.tryParse(base);
  if (uri == null || uri.host.isEmpty) {
    return const EngineAddressRejected(
      "That address has no server name in it — check it against your server's "
      'own address.',
    );
  }
  return EngineAddressReady(base);
}

/// True for `http://…` / `https://…`, in any casing.
///
/// Checked before anything else because `Uri.parse` does not fail on a missing
/// scheme — it reads `localhost:8080/v1` as scheme `localhost`, and the request
/// then dies as an unnamed transport error rather than as anything a person
/// could act on.
bool _hasWebScheme(String value) {
  final lower = value.toLowerCase();
  return lower.startsWith('http://') || lower.startsWith('https://');
}

String _withoutTrailingSlashes(String value) {
  var out = value;
  while (out.endsWith('/')) {
    out = out.substring(0, out.length - 1);
  }
  return out;
}

/// [value] with one trailing OpenAI endpoint removed, if it carries one.
///
/// Matched case-insensitively but cut by length, so the surviving prefix keeps
/// the exact bytes the user typed — a path may well be case-sensitive on the
/// far side, and this function is not in the business of rewriting it.
String _withoutEndpointPath(String value) {
  final lower = value.toLowerCase();
  for (final path in _openAiPaths) {
    if (lower.endsWith(path)) {
      return _withoutTrailingSlashes(
        value.substring(0, value.length - path.length),
      );
    }
  }
  return value;
}
