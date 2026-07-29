import '../../agents/logic/connector_token.dart';
import '../../agents/logic/mcp_server.dart';
import 'connector_catalog.dart';

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
/// The agent's config is the only source of "connected". The catalog's own
/// `installed` flag says the *account* is linked at the backend, which is not
/// the same claim: an account can be linked while this computer's agent has no
/// server for it, and the screen must not promise a tool the agent can't call.
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
        imageUrl: byCode[server.name]?.imageUrl ?? '',
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
          status: ConnectorStatus.notConnected,
          catalogEntry: entry,
          token: tokens[entry.code],
        ),
  ];
  return [...connected, ...offered];
}
