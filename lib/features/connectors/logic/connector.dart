import '../../../infrastructure/api/connector_gateway_client.dart';
import '../../agents/logic/mcp_server.dart';
import 'connector_catalog.dart';
import 'connector_link_status.dart';

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
    this.linkStatus = ConnectorLinkStatus.notInstalled,
    this.linkError = '',
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

  /// Where the *account link* stands at the backend, which is a different
  /// question from [status]: this says whether the user has signed in and
  /// whether the token has reached this machine, while [status] says whether
  /// the agent has a server it can call. A row is only truly usable when both
  /// agree, which is why [ConnectorLinkStatus.connecting] renders as a disabled
  /// pill rather than as connected.
  final ConnectorLinkStatus linkStatus;

  /// Why the last link attempt failed, shown in the row's tooltip.
  final String linkError;

  bool get connected => status == ConnectorStatus.connected;

  /// True while the backend still owes an answer — the screen keeps polling.
  bool get isSettling => linkStatus.isSettling;

  /// Which bucket the row belongs in. A connector mid-flight counts as linked
  /// so it doesn't jump between sections under the user's cursor.
  bool get inConnectedBucket => connected || linkStatus.isLinked;
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
  List<DeviceConnector> deviceConnectors = const [],
}) {
  final byCode = {for (final entry in catalog) entry.code: entry};
  final linked = {for (final device in deviceConnectors) device.code: device};
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
        linkStatus:
            linked[server.name]?.status ?? ConnectorLinkStatus.connected,
        linkError: linked[server.name]?.errorMessage ?? '',
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
          linkStatus:
              linked[entry.code]?.status ?? ConnectorLinkStatus.notInstalled,
          linkError: linked[entry.code]?.errorMessage ?? '',
        ),
  ];
  return [...connected, ...offered];
}
