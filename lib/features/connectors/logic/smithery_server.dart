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
  ///
  /// The registry also returns `verified` and `useCount`. Neither is modelled:
  /// nothing reads them, the list is ordered by the registry rather than here,
  /// and a "Verified" badge sat on nearly every row — a mark almost everything
  /// carries separates nothing. Parsing a field to leave it unused only makes
  /// the model look like it has an opinion it doesn't.
  final bool deployed;

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
