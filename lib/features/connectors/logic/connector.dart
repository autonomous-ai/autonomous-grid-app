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

  /// Linked at the gateway but with no credential on this machine.
  ///
  /// A real and confusing state without a name: the user connected this from
  /// their laptop, and here the agent has nothing. The row offers Connect and
  /// says why rather than showing a checkmark it can't back up.
  bool get linkedElsewhere =>
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
/// and say so ([Connector.linkedElsewhere]) rather than showing a state the
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
        name: byCode[server.name]?.label ?? server.name,
        description: mcpServerSummary(server),
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
