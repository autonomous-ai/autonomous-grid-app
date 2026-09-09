/// The empty page every engine starts on, and the one it falls back to when it
/// refuses a navigation outright.
const blankPage = 'about:blank';

/// Where a search goes when what the user typed isn't an address.
///
/// Three, because a search engine is the one browser setting people genuinely
/// disagree about — and because the address bar sends what you typed to
/// whichever one this names, which is not a choice to make on someone's behalf.
/// Settings ▸ Browser picks it; [ChatPrefs.browserSearchEngine] stores the id.
enum BrowserSearchEngine {
  google('google', 'Google', 'https://www.google.com/search?q='),
  duckDuckGo('duckduckgo', 'DuckDuckGo', 'https://duckduckgo.com/?q='),
  bing('bing', 'Bing', 'https://www.bing.com/search?q=');

  const BrowserSearchEngine(this.id, this.label, this.queryPrefix);

  /// What the settings file stores. Its own string rather than [name] so
  /// renaming the constant can't silently reset everyone's choice.
  final String id;

  final String label;

  /// The search URL up to the query, which is appended encoded.
  final String queryPrefix;

  /// The engine [id] names, falling back to [google] for an id written by an
  /// older build — or by hand.
  static BrowserSearchEngine byId(String id) {
    for (final engine in values) {
      if (engine.id == id) return engine;
    }
    return google;
  }
}

/// A host that only means something on this computer — `localhost:3000` and the
/// loopback addresses a dev server binds to.
///
/// Matched before anything is parsed, because `localhost:3000` reads as the
/// scheme `localhost` to every URL parser there is.
final _localAddress = RegExp(
  r'^(?:localhost|127(?:\.\d{1,3}){3}|0\.0\.0\.0|\[[0-9a-f:]+\])'
  r'(?::\d+)?(?:[/?#].*)?$',
  caseSensitive: false,
);

/// A host carrying a port: `example.com:8080/admin`.
///
/// Matched before anything is parsed, and this is not fussiness — a dot is a
/// legal character in a URI scheme, so `example.com:8080` parses as the scheme
/// `example.com`, lands in the "a scheme this tab can't draw" branch below and
/// is refused. Orca's own address bar has the same hole. The colon must be
/// followed by digits and the name may hold no `:` or `@`, so `mailto:a@b.com`
/// — which is host-shaped by every looser test — stays out.
final _hostWithPort = RegExp(
  r'^[^\s/?#:@]+\.[a-z]{2,}:\d+(?:[/?#].*)?$',
  caseSensitive: false,
);

/// Input shaped like a host: a dot, a letters-only suffix after it, then an
/// optional port and an optional path.
///
/// The port and the path are the part Orca's own pattern leaves out, and
/// without them `example.com:8080/x` — a perfectly ordinary address — is
/// searched for instead of opened.
final _looksLikeHost = RegExp(
  r'^[^\s/?#]+\.[a-z]{2,}(?::\d+)?(?:[/?#].*)?$',
  caseSensitive: false,
);

/// What the address bar does with what the user typed: an address to open, or
/// null when there was nothing to act on.
///
/// The order is the whole logic. A local dev address first (see
/// [_localAddress]), then a path off this computer's disk, then anything
/// already carrying a scheme, then a bare host — and a search for everything
/// left, which is how "react hooks" and "3.14" both end up somewhere useful
/// rather than at `https://3.14`.
///
/// A scheme the app can't draw — `mailto:`, `javascript:` — returns null: the
/// caller says so rather than silently searching for the text.
String? addressBarUrl(
  String typed, {
  BrowserSearchEngine engine = BrowserSearchEngine.google,
}) {
  final trimmed = typed.trim();
  if (trimmed.isEmpty) return null;

  if (_localAddress.hasMatch(trimmed)) return 'http://$trimmed';

  if (_hostWithPort.hasMatch(trimmed)) return 'https://$trimmed';

  // A path the user typed themselves — an `.html` the assistant just wrote.
  // POSIX only: Windows isn't built yet (see `.github/workflows/release.yml`),
  // and `windows: false` is what keeps this function's answer the same wherever
  // the test for it runs.
  if (trimmed.startsWith('/')) {
    return Uri.file(trimmed, windows: false).toString();
  }

  final parsed = Uri.tryParse(trimmed);
  if (parsed != null && parsed.hasScheme) {
    return switch (parsed.scheme.toLowerCase()) {
      'http' || 'https' || 'file' => parsed.toString(),
      _ => null,
    };
  }

  if (_looksLikeHost.hasMatch(trimmed)) return 'https://$trimmed';

  return searchUrlFor(trimmed, engine);
}

/// [query] as a search on [engine], ready to open.
String searchUrlFor(String query, BrowserSearchEngine engine) =>
    '${engine.queryPrefix}${Uri.encodeQueryComponent(query)}';

/// What the app does with a navigation the *page* started — a clicked link, a
/// redirect, a `window.location` from a script.
///
/// Typed input is the other door ([addressBarUrl]) and it is deliberately more
/// generous: the user asking for a file off their own disk is not the same act
/// as a page on the internet asking for one.
enum PageNavigation {
  /// Ordinary web navigation. Let it happen.
  allow,

  /// Not a web page — a mail link, a Zoom link, an app's own scheme. The OS
  /// knows what opens it and this tab does not.
  openInSystemBrowser,

  /// A scheme a remote page has no business sending this tab to.
  block,
}

/// Which of the three [url] is. Pure, so the policy can be read in one place
/// instead of inferred from a chain of `if`s inside a callback.
PageNavigation classifyPageNavigation(String? url) {
  if (url == null || url.trim().isEmpty) return PageNavigation.block;
  final parsed = Uri.tryParse(url.trim());
  if (parsed == null) return PageNavigation.block;
  return switch (parsed.scheme.toLowerCase()) {
    // Schemeless is a relative link the page is resolving against itself.
    'http' || 'https' || 'about' || '' => PageNavigation.allow,
    // `file:` is the one this list exists for: a page that can reach the disk
    // can read what the user has, and no site needs to.
    'file' || 'javascript' || 'data' || 'blob' => PageNavigation.block,
    _ => PageNavigation.openInSystemBrowser,
  };
}

/// What to call [url] when there is no room for the whole thing — the site's
/// host, or the address itself when it has none.
String hostLabel(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  return host.isEmpty ? url : host;
}

/// What to write on the tab: the page's own title, the site it came from, or
/// the word the tab was opened under while it is still empty.
///
/// A browser tab that stays called "Browser" is the one thing a row of them
/// can't be told apart by — the same reason every browser puts the title there.
String browserTabTitle({
  required String title,
  required String url,
  required String fallback,
}) {
  if (title.trim().isNotEmpty) return title.trim();
  if (url.trim().isEmpty) return fallback;
  return hostLabel(url);
}
