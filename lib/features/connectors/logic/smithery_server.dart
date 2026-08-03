/// How the fetched rows are ordered.
///
/// **Applied to what has been fetched, not to the directory.** The registry
/// accepts no sort parameter (measured: `sort`, `sortBy` and `order` all return
/// the identical page), so this can only order the pages already loaded. That is
/// an honest limit rather than a broken feature, but it does mean sorting by
/// name reaches further as the user loads more.
///
/// **[mostUsed] is the default.** [relevance] was, and it reads as arbitrary:
/// the registry's order is not by anything the screen shows, so a 5,000-use
/// server sits above a 60,000-use one for reasons nobody can see. Measured, the
/// unfiltered first page runs Exa (12k), Agent News (39k), Keenable (10k) — up
/// and down with no pattern a user can follow.
///
/// The cost, and it is real: the other two orders reshuffle the *whole*
/// accumulated list, so a popular row arriving on page three jumps to the top
/// and shifts what the user was reading. [relevance] is the only order that only
/// ever grows at the end, which is why it is still here.
enum SmitheryServerSort {
  /// The registry's own order, untouched.
  ///
  /// **Not most-used-first**, though it correlates: measured 2026-08-03 the
  /// first page runs Gmail (60,499), Jina (76,715), Brave (60,204), Exa
  /// (12,491) — recognisable services first, by a ranking the registry does not
  /// publish. Good enough to be the default, and the only order that survives
  /// paging without moving what is already on screen.
  relevance('Relevance'),

  /// Strictly by [SmitheryServer.useCount], descending — the closest thing the
  /// directory has to a star count.
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
