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

  bool get connected => status == ConnectorStatus.connected;
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
        ),
  ];
  return [...connected, ...offered];
}
