/// A narrowing the **registry** applies, as a token inside the search string.
///
/// Server-side on purpose. The alternative — fetch everything and filter here —
/// cannot work against a directory that caps browsing at 500 rows: filtering
/// locally would search only the 500 already seen, while a token narrows the
/// whole 4,078 before the cap applies. `is:remote is:verified` is 199 rows, all
/// of them reachable; the same filter applied to a fetched page would show a
/// handful and claim that was all there is.
///
/// Counts measured 2026-08-03 against the live registry.
///
/// **Only tokens that were verified to actually work belong here.**
/// `owner:smithery` was written, measured and removed in the same sitting: it
/// reports 100 results whose rows come back `bySmithery: false`, and only 2 in
/// 10 `remote: true` even when combined with `is:remote`. A filter the registry
/// answers with the wrong rows is worse than no filter, because the user cannot
/// tell. Check any new token against the *fields of the rows it returns*, not
/// against the fact that the count changed.
enum SmitheryFilter {
  /// Smithery vouches for it — 199 of the 4,078 remote entries.
  ///
  /// The one filter worth offering: a public directory anyone can publish to is
  /// not something to put in front of a person unsorted, and this is the
  /// registry's own answer to which rows it stands behind. Measured as honest —
  /// `is:remote is:verified` returns rows that are 10/10 remote and 10/10
  /// verified.
  verified('is:verified', 'Verified');

  const SmitheryFilter(this.token, this.label);

  /// The registry's own search token.
  final String token;

  /// What the pill says.
  final String label;
}

/// How the fetched rows are ordered.
///
/// **Applied to what has been fetched, not to the directory.** The registry
/// accepts no sort parameter (measured: `sort`, `sortBy` and `order` all return
/// the identical page), so this can only order the pages already loaded. That is
/// an honest limit rather than a broken feature — the registry's own default is
/// most-used-first, which is what [SortOrder.relevance] preserves — but it does
/// mean sorting by name reaches further as the user loads more.
enum SmitheryServerSort {
  /// The registry's own order, untouched. Most-used first in practice.
  relevance('Relevance'),

  /// Most-used first, explicitly — identical to the registry's default for the
  /// first page, and meaningful once filters have reshuffled things.
  mostUsed('Most used'),

  /// Alphabetical, for finding a name you already know.
  name('Name');

  const SmitheryServerSort(this.label);

  final String label;

  /// [servers], ordered. Never sorts in place — the caller's list is state.
  List<SmitheryServer> apply(List<SmitheryServer> servers) {
    switch (this) {
      case SmitheryServerSort.relevance:
        return servers;
      case SmitheryServerSort.mostUsed:
        return [...servers]..sort((a, b) => b.useCount.compareTo(a.useCount));
      case SmitheryServerSort.name:
        return [...servers]..sort(
          (a, b) => a.displayName.toLowerCase().compareTo(
            b.displayName.toLowerCase(),
          ),
        );
    }
  }
}

/// One entry in the Smithery registry — a public directory of MCP servers.
///
/// This is a *browse* model, not a connector. Nothing here is written anywhere:
/// a row becomes real only when the user connects it, and at that point it goes
/// through exactly the same path as a hand-typed URL (probe → DCR sign-in →
/// token in the master store). The registry is a way to find an address, and the
/// app treats the address it produces no differently from one typed by hand.
class SmitheryServer {
  const SmitheryServer({
    required this.qualifiedName,
    required this.displayName,
    this.description = '',
    this.iconUrl = '',
    this.remote = false,
    this.deployed = false,
    this.verified = false,
    this.useCount = 0,
    this.bySmithery = false,
  });

  /// `namespace/slug`, or a bare `namespace` for Smithery's own servers
  /// (`jina`, `gmail`). This is the key everything else is derived from.
  final String qualifiedName;

  final String displayName;
  final String description;
  final String iconUrl;

  /// Reachable over HTTP at all. A registry entry that is not remote describes a
  /// package you run yourself, and there is no URL to connect to.
  final bool remote;

  /// Smithery is currently hosting it.
  final bool deployed;

  /// Smithery vouches for this entry.
  ///
  /// **Previously not modelled, and the reasoning has been overturned by
  /// measurement.** The earlier note said a "Verified" badge sat on nearly every
  /// row, so the mark separated nothing. That was read off a page of the
  /// *default* listing — which the registry returns most-used first, and the
  /// most-used are exactly the vouched-for ones. Across the directory it
  /// separates a great deal: `is:remote` is **4,078** rows and
  /// `is:remote is:verified` is **199** (measured 2026-08-03).
  ///
  /// So this is not a badge, it is the filter that makes 4,000 community servers
  /// safe to put in front of someone. Still not rendered as a mark on every row
  /// for the original reason.
  final bool verified;

  /// How many times the directory has seen this server used.
  ///
  /// The only quality signal that is a *number*, and the only thing the app can
  /// sort by: the registry accepts no sort parameter of its own (measured — all
  /// of `sort`, `sortBy` and `order` return identical pages), so ordering is
  /// this field, applied to what has been fetched.
  final int useCount;

  /// Published by Smithery itself rather than by a community author.
  final bool bySmithery;

  /// This row can be connected from here.
  ///
  /// Both flags, not just [remote]: an entry can be remote-capable and not
  /// currently hosted, and its gateway URL 404s. Filtering it out is kinder than
  /// a Connect button that fails on press.
  bool get connectable => remote && deployed && qualifiedName.isNotEmpty;

  /// The address to put in the agent's config.
  ///
  /// Measured, not guessed. Three URL shapes exist for a Smithery server and
  /// only this one is the MCP endpoint:
  ///
  /// | URL | what it does |
  /// |---|---|
  /// | `server.smithery.ai/<qualifiedName>/mcp` | **401 + `WWW-Authenticate`** with `resource_metadata` — the OAuth-guarded MCP endpoint |
  /// | `server.smithery.ai/<qualifiedName>/sse` | 404 `Server not found` — SSE is gone |
  /// | the registry's own `deploymentUrl` | 404 on `/mcp` — it is the container, not the gateway |
  ///
  /// The 401 is the point: it carries the pointer to the authorization server,
  /// which is what `McpAuthProbe` follows and what makes Connect work without a
  /// Smithery API key or a paid plan.
  ///
  /// Verified 2026-07-31 against a bare name (`jina`) and a namespaced one
  /// (`pinkpixel-dev/web-scout-mcp`).
  String get mcpUrl => 'https://server.smithery.ai/$qualifiedName/mcp';

  /// The key this server would take in the agent's config.
  ///
  /// Slashes become hyphens because the key is read by humans in `config.yaml`
  /// and a `/` in a YAML key invites quoting bugs. It does not need to be
  /// sanitized further: Hermes maps the key through
  /// `sanitize_mcp_name_component` when it builds `mcp__<server>__<tool>`, so
  /// the charset here is a readability choice, not a correctness one.
  String get suggestedName => qualifiedName.replaceAll('/', '-');

  static SmitheryServer? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final qualified = raw['qualifiedName'];
    if (qualified is! String || qualified.trim().isEmpty) return null;
    final display = raw['displayName'];
    return SmitheryServer(
      qualifiedName: qualified.trim(),
      // The registry allows a blank display name; the qualified name is always
      // there and is what the user searched by anyway.
      displayName: display is String && display.trim().isNotEmpty
          ? display.trim()
          : qualified.trim(),
      description: raw['description'] is String ? raw['description'] : '',
      iconUrl: raw['iconUrl'] is String ? raw['iconUrl'] : '',
      remote: raw['remote'] == true,
      deployed: raw['isDeployed'] == true,
      verified: raw['verified'] == true,
      // `num`, not `int`: JSON has one number type and a count that arrives as
      // `1.0` would otherwise silently become zero and sort to the bottom.
      useCount: raw['useCount'] is num ? (raw['useCount'] as num).toInt() : 0,
      bySmithery: raw['bySmithery'] == true,
    );
  }
}

/// One page of registry results, plus where it sits in the whole.
class SmitheryPage {
  const SmitheryPage({
    required this.servers,
    required this.page,
    required this.totalPages,
    required this.totalCount,
  });

  final List<SmitheryServer> servers;
  final int page;
  final int totalPages;
  final int totalCount;

  /// There is at least one more page to ask for.
  bool get hasMore => page < totalPages;

  /// Parses `{servers: [...], pagination: {...}}`.
  ///
  /// Lenient in the same way the connector catalog is: a row the app cannot read
  /// drops itself and the rest of the page still renders. A directory of 7,500
  /// community servers will contain malformed entries, and one of them must not
  /// blank the dialog.
  ///
  /// Non-connectable entries are dropped here rather than in the UI, so
  /// "everything in this list can be connected" is a property of the model and
  /// not a rule each widget has to remember.
  static SmitheryPage? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final rows = raw['servers'];
    if (rows is! List) return null;
    final pagination = raw['pagination'];
    int number(String key, int fallback) {
      final value = pagination is Map ? pagination[key] : null;
      return value is num ? value.toInt() : fallback;
    }

    final servers = <SmitheryServer>[];
    for (final row in rows) {
      final server = SmitheryServer.fromJson(row);
      if (server != null && server.connectable) servers.add(server);
    }
    return SmitheryPage(
      servers: servers,
      page: number('currentPage', 1),
      // Defaulting to the current page means "no more" — a missing pagination
      // block must not produce an infinite Load more.
      totalPages: number('totalPages', number('currentPage', 1)),
      totalCount: number('totalCount', servers.length),
    );
  }
}
