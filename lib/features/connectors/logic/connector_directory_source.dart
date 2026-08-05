/// Where the Connectors screen gets the list of things you can connect.
///
/// Two directories are wired, and **both stay wired**. Switching is one line —
/// [kConnectorDirectorySource] — because which one is right is a product
/// question that has changed once already and may change again, and a source
/// that has been deleted cannot be switched back to.
///
/// They are not interchangeable in shape, which is why this enum carries their
/// differences rather than leaving each caller to remember them:
///
/// | | [gateway] | [smithery] |
/// |---|---|---|
/// | Rows | 12, curated (measured 2026-08-05) | ~4,000, anyone can publish |
/// | Delivery | one flat list | pages of 50 |
/// | Search | none — filter locally | server-side |
/// | Sign-in | Grid brokers it (`auth_type: app`) | the server itself (DCR) |
/// | Needs a Grid session | **yes** | no |
/// | Token lives | backend, pulled to this machine | this machine only |
enum ConnectorDirectorySource {
  /// `GET {gridApiUrl}/v1/grid/connectors` — Autonomous's own curated list.
  ///
  /// Measured 2026-08-05 against the live backend: 12 rows, every one
  /// `auth_type: app`, all with a logo, 8 of 12 carrying an `mcp_url`. The four
  /// without it (`figma-api-app`, `gmail`, `google_calendar`, `google_drive`)
  /// are `mcp_ready: false` — connectable, but no tools behind them yet.
  gateway,

  /// `api.smithery.ai/servers` — the public MCP registry.
  smithery,
}

/// The directory in force.
///
/// **This is the switch.** Change it to [ConnectorDirectorySource.smithery] and
/// hot-restart; nothing else needs touching, because everything that differs
/// between the two is expressed on this enum and dispatched in
/// `BrowseConnectorsController`.
const ConnectorDirectorySource kConnectorDirectorySource =
    ConnectorDirectorySource.gateway;

/// What the active source can do, so the screen can ask instead of assuming.
///
/// These exist as properties rather than as `if (source == …)` at each call
/// site for one reason: the assumptions were previously baked in — infinite
/// scroll, a sort control, a search that skipped local filtering — all written
/// when there was only ever a paged registry underneath. Each of those is wrong
/// for a flat list of twelve, and finding every one of them again on the next
/// switch is exactly the cost this avoids.
extension ConnectorDirectoryCapabilities on ConnectorDirectorySource {
  /// The directory hands out more rows as you scroll.
  ///
  /// False for [ConnectorDirectorySource.gateway]: its response *is* the whole
  /// catalog, so there is no next page and infinite scroll has nothing to ask
  /// for.
  bool get isPaged => this == ConnectorDirectorySource.smithery;

  /// The search box goes to the server.
  ///
  /// When false the screen filters the rows it already has, which is both
  /// instant and complete for twelve of them — and means no debounce, because
  /// there is no request to hold back.
  bool get searchesRemotely => this == ConnectorDirectorySource.smithery;

  /// Rows carry a usage count worth ordering or badging by.
  ///
  /// The gateway publishes no such number. A sort control over a field that is
  /// zero for every row is a control that does nothing, and a star badge
  /// showing "0" reads as a verdict rather than as "not applicable".
  bool get hasPopularity => this == ConnectorDirectorySource.smithery;

  /// Browsing would be crowded out by the rows already connected, so Browse
  /// leaves them to the Connected pill.
  ///
  /// **True only because the directory is enormous.** On the public registry
  /// seven connected rows measured 281px — 63% of the list area on a 700px
  /// window — leaving about one card's worth of room for the four thousand the
  /// user opened Browse to look through.
  ///
  /// A curated list of twelve has the opposite problem. Hiding the three that
  /// are connected shows nine of twelve with nothing saying the others exist,
  /// so the catalog reads as incomplete and the connected ones look missing
  /// rather than done. There they stay in Browse, marked as connected, under
  /// their own section heading.
  bool get hidesConnectedRows => this == ConnectorDirectorySource.smithery;

  /// Browsing requires a signed-in Grid session.
  ///
  /// The gateway authenticates every call with the app's session Bearer;
  /// Smithery answers anyone. The screen needs the difference so a signed-out
  /// user is told to sign in rather than shown an empty list.
  bool get needsSession => this == ConnectorDirectorySource.gateway;
}
