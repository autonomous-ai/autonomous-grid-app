import '../../agents/logic/connector_token.dart';
import '../../agents/logic/mcp_server.dart';
import 'connector_catalog.dart';
import 'favicon_url.dart';

/// How a connector came to exist.
enum ConnectorKind {
  /// An MCP server the user configured by hand — command line or URL.
  customMcp,

  /// An entry from the catalog of sign-in services. Until the sign-in flow
  /// ships these can only be offered; afterwards, connecting one materializes
  /// an MCP server in the agent's config like any other.
  catalog,
}

enum ConnectorStatus { connected, notConnected }

/// One row on the Connectors screen: something that links the assistant to the
/// outside, whether it's live in the agent's config or still on offer.
class Connector {
  const Connector({
    required this.id,
    required this.kind,
    required this.name,
    required this.description,
    required this.status,
    this.imageUrl = '',
    this.server,
    this.catalogEntry,
    this.token,
  });

  /// The catalog `code`, or the MCP server's name — unique either way, because
  /// a connected catalog entry takes its server's name.
  final String id;

  final ConnectorKind kind;
  final String name;
  final String description;

  /// The service's mark, when the catalog has one. Empty for a hand-configured
  /// server, and the row draws a transport glyph instead.
  final String imageUrl;

  final ConnectorStatus status;

  /// The materialized entry in the agent's config, when [status] is connected.
  final McpServer? server;

  /// The catalog entry behind this row, when there is one.
  final ConnectorCatalogEntry? catalogEntry;

  /// The credential this machine holds for the connector, when it has one.
  ///
  /// Its presence — not the gateway's `status` field — is what makes a row read
  /// as connected. The gateway knows the *account* is linked, which may have
  /// happened on another computer entirely (D6).
  final ConnectorToken? token;

  bool get connected => status == ConnectorStatus.connected;

  /// The account has authorized this connector, and this machine holds no
  /// credential for it.
  ///
  /// Named for what is *known* rather than for a cause. It used to be
  /// `linkedElsewhere`, and both the name and the line it drove asserted a
  /// second computer — which is only one of three ways to arrive here, and was
  /// wrong the first time it was read in anger:
  ///
  ///   1. It really was another computer. The case the state was added for.
  ///   2. **The gateway renamed the connector.** Measured 2026-07-30: the
  ///      catalog went from `gmail` / `gmail-app` / `gmail-pat` to a single
  ///      `gmail`, so a token stored under the old code stops matching the row
  ///      and the account looks linked from nowhere.
  ///   3. The credential went missing here without the gateway hearing about
  ///      it — a store rewritten, a disconnect that failed after the server
  ///      call.
  ///
  /// The app cannot tell these apart: all it sees is a `status` and an absence.
  /// So it states the absence and offers the fix, and guesses at nothing.
  bool get needsSignInHere =>
      token == null && (catalogEntry?.linkedAtServer ?? false);

  /// Signed in, but the connector has no MCP server, so the agent still can't
  /// call anything. Five connectors are in this state today.
  bool get connectedButUnusable => token != null && !token!.isUsable;

  /// Whether Connect can be offered at all: the app can only drive an OAuth
  /// flow, and there has to be something for the agent to call afterwards.
  bool get canConnect => catalogEntry?.canConnectFromApp ?? false;
}

/// Join the agent's config (the truth about what's live) with the catalog (the
/// offer): a config entry is a connected connector; a catalog entry with no
/// config entry of the same name is an available one. One row per thing — a
/// connected catalog service shows once, as its live server.
///
/// "Connected" means **this machine holds the credential** — either as an MCP
/// server in the agent's config, or as a token in the app's own store. Both are
/// local facts, and either one alone is enough: a token arrives first and the
/// projection into the agent follows, so a row that waited for the config entry
/// would sit under "Available" for the moment right after a successful sign-in,
/// which reads as the sign-in having failed.
///
/// What is deliberately *not* enough is the gateway's own `status: connected`.
/// That says the account is linked somewhere — quite possibly another computer
/// — and this agent still has nothing to call. Those rows stay under Available
/// and say so ([Connector.needsSignInHere]) rather than showing a state the
/// machine can't back up (D6).
List<Connector> buildConnectors({
  required List<McpServer> servers,
  required List<ConnectorCatalogEntry> catalog,
  Map<String, ConnectorToken> tokens = const {},
}) {
  final byCode = {for (final entry in catalog) entry.code: entry};
  final connected = <Connector>[
    for (final server in servers)
      Connector(
        id: server.name,
        kind: byCode.containsKey(server.name)
            ? ConnectorKind.catalog
            : ConnectorKind.customMcp,
        name: byCode[server.name]?.label ?? capitalizeFirst(server.name),
        description: _describe(byCode[server.name], server),
        // The catalog's own mark first — it is the one the gateway chose, and
        // the only one guaranteed to be the service's real logo. A server the
        // user typed has no catalog entry at all, so its icon is derived from
        // the host it points at (and skipped entirely for private hosts).
        imageUrl: _markFor(byCode[server.name], server),
        status: ConnectorStatus.connected,
        server: server,
        catalogEntry: byCode[server.name],
        token: tokens[server.name],
      ),
  ];
  final taken = {for (final server in servers) server.name};
  final offered = <Connector>[
    for (final entry in catalog)
      if (!taken.contains(entry.code))
        Connector(
          id: entry.code,
          kind: ConnectorKind.catalog,
          name: entry.label,
          description: entry.description,
          imageUrl: entry.imageUrl,
          // A token here and no server yet is the normal state in the seconds
          // after a sign-in, and a lasting one for a connector with no MCP
          // server at all. Either way the credential is on this machine, so the
          // row belongs under Connected — with "No tools yet" saying what is
          // still missing.
          status: tokens.containsKey(entry.code)
              ? ConnectorStatus.connected
              : ConnectorStatus.notConnected,
          catalogEntry: entry,
          token: tokens[entry.code],
        ),
  ];
  return [...connected, ...offered];
}

/// A config key shown as a name: same string, first letter raised.
///
/// Only ever applied where the display name **is** the config key — a server
/// with no catalog entry behind it. Those keys are typed by a person or derived
/// from a directory slug (`bigquery`, `jina`, `subwayinfo`), and a column of
/// lowercase rows between `Figma` and `Google Drive` reads as a different class
/// of thing rather than the same list.
///
/// Deliberately *only* the first letter. [labelFromCode] would also split on
/// hyphens and title-case every word, which is right for a code the gateway
/// coined and wrong here: this name may have been typed, and turning someone's
/// `my-notes` into `My Notes` is rewriting their choice rather than tidying a
/// slug. A leading digit or symbol is left alone — `1password` has no letter to
/// raise, and `toUpperCase` on it is a no-op anyway.
String capitalizeFirst(String value) {
  if (value.isEmpty) return value;
  return value[0].toUpperCase() + value.substring(1);
}

/// What a connected row *is*, in words — the catalog's blurb, or its address.
///
/// Same precedence as [_markFor], for the same reason: the gateway's blurb
/// describes the service, the address describes the plumbing. This used to be
/// the address unconditionally, which meant a signed-in Gmail's detail dialog
/// opened on `http://127.0.0.1:61755/c/gmail/mcp` — the app's own bridge port,
/// which changes between launches and says nothing about Gmail. The blurb was
/// sitting in `catalogEntry` the whole time, thrown away at exactly the moment
/// the connector became interesting.
///
/// The address stays the answer for a server the user typed in: there is no
/// blurb for one of those, and the address is the only thing distinguishing two
/// hand-added servers from each other.
/// Deliberately not "blurb, or else the address": a catalog connector with an
/// empty blurb falls through to *no description at all*, not to its URL. Those
/// are the rows whose URL is the bridge, so the fallback would reintroduce the
/// loopback line for exactly the connectors it was removed from.
///
/// **The address is also suppressed when it points at this app.** Having no
/// catalog entry is not proof the row is hand-written: the catalog is a page of
/// *search results*, so picking a category the connector does not match drops
/// its entry and this fell straight through to
/// `http://127.0.0.1:61755/c/gmail/mcp` on a signed-in Gmail — measured
/// 2026-08-04 with the Finance pill selected. Asking the URL is what
/// distinguishes the two cases; the transport cannot, because MCP-over-bridge
/// (D32) looks exactly like a real MCP server from there.
String _describe(ConnectorCatalogEntry? entry, McpServer server) {
  if (entry != null) return entry.description;
  final summary = mcpServerSummary(server);
  return isBridgeAddress(summary) ? '' : summary;
}

/// Whether [text] is one of this app's own loopback bridge addresses.
///
/// Deliberately a shape test rather than an equality check against the live
/// port: the port moves between launches, a row can have been written by an
/// earlier one, and this has to be right for a value that is already stale.
/// Every bridge URL is loopback with a `/c/<connector>/mcp` path, and nothing a
/// user would type by hand looks like that.
bool isBridgeAddress(String text) {
  final uri = Uri.tryParse(text.trim());
  if (uri == null || !uri.hasScheme) return false;
  final host = uri.host;
  final loopback = host == '127.0.0.1' || host == 'localhost' || host == '::1';
  return loopback && uri.path.startsWith('/c/');
}

/// The mark for a configured server: the catalog's, or one derived from its host.
///
/// Order matters. A catalog entry's `image_url` is the service's real logo,
/// chosen by the gateway; a favicon is a guess made from a hostname. Preferring
/// the guess would replace a correct mark with a worse one for every connector
/// the gateway does know.
///
/// Only HTTP servers get a derived mark. A stdio server is a local command with
/// no host to ask about — `npx` has no logo — so those keep the transport glyph.
String _markFor(ConnectorCatalogEntry? entry, McpServer server) {
  final fromCatalog = entry?.imageUrl ?? '';
  if (fromCatalog.isNotEmpty) return fromCatalog;
  return switch (server.transport) {
    McpHttp(:final url) => faviconUrl(url),
    McpStdio() => '',
  };
}
