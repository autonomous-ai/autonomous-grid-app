import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/connector_catalog_client.dart';

/// How a catalog service is signed into.
enum ConnectorAuthMethod {
  /// The connector signs in through Grid — the app opens a browser and the
  /// account is linked. Everything the API returns today is this.
  app,

  /// The user brings their own MCP endpoint or key. Kept because the field is
  /// free text on the wire and an unknown value must not drop the row.
  manual,
}

/// One service in the connectors catalog, as the backend describes it.
///
/// Mirrors the API payload rather than the screen: `code` is the stable
/// identity (`gmail`, `figma-api`), `label` is what the user reads. The row
/// widget decides what to show — the model just carries it.
class ConnectorCatalogEntry {
  const ConnectorCatalogEntry({
    required this.id,
    required this.code,
    required this.label,
    required this.description,
    this.imageUrl = '',
    this.mcpUrl = '',
    this.order,
    this.installed = false,
    this.authMethod = ConnectorAuthMethod.app,
    this.mcpReady = false,
    this.linkedAtServer = false,
    this.accountName = '',
    this.canRefresh = false,
  });

  /// The backend's own id. Opaque to the app.
  final String id;

  /// The stable slug (`gmail`, `google_drive`, `figma-api`). This is what a
  /// configured MCP server is matched against, so it doubles as the row key.
  final String code;

  /// The name the user reads ("Google Drive", "monday.com").
  final String label;

  /// The backend's blurb. Often several sentences — the row shows one line and
  /// puts the rest in a tooltip.
  final String description;

  /// The service's mark, on the CDN. Empty when the backend has none, and the
  /// row falls back to a glyph badge rather than an empty square.
  final String imageUrl;

  /// The provider's MCP endpoint, when the backend publishes one.
  final String mcpUrl;

  /// The backend's own ordering. Null sorts last — an entry with no opinion
  /// shouldn't jump ahead of one that has.
  final int? order;

  /// The backend says this account is already linked. Not the same as "the
  /// agent has an MCP server for it" — see [Connector].
  final bool installed;

  final ConnectorAuthMethod authMethod;

  /// The gateway has an MCP server for this connector.
  ///
  /// When false, signing in genuinely works — the credential is stored
  /// server-side — and the agent still cannot call anything, because there is
  /// no server to add. Five connectors are in exactly this state today
  /// (`atlassian`, `discord`, `gmail-app`, `google_calendar`, `google_drive`),
  /// so this is a real case rather than a defensive one. The row must not offer
  /// Connect: walking a whole OAuth round trip to receive nothing usable is
  /// worse than a button that visibly isn't ready.
  final bool mcpReady;

  /// The user has authorized this connector *somewhere* — possibly on another
  /// computer. Not the same as "this machine can use it", which only the
  /// agent's own config can answer (D6).
  final bool linkedAtServer;

  /// The account name at the provider, when they return one.
  final String accountName;

  /// The provider issues refresh tokens, so `/refresh` is worth calling.
  final bool canRefresh;

  /// The two gates that must both pass before Connect is offered: the app can
  /// only drive an OAuth flow (`pat` needs a hand-pasted token and has no flow
  /// at all), and there must be something for the agent to call afterwards.
  bool get canConnectFromApp =>
      authMethod == ConnectorAuthMethod.app && mcpReady;
}

/// The catalog format is versioned so a bundled file from a newer world is
/// refused rather than misread. Only the bundled asset carries it — the API
/// speaks its own envelope.
const int kConnectorCatalogVersion = 1;

/// Parse the bundled `assets/connectors/catalog.json`.
///
/// Lenient the same way every shared-file reader here is: an entry that can't
/// be read is dropped and the rest still show. A catalog from a newer world
/// (version > ours) reads as empty rather than as half-understood rows.
List<ConnectorCatalogEntry> parseConnectorCatalog(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const [];
  }
  if (decoded is! Map<String, dynamic>) return const [];
  final version = decoded['version'];
  if (version is! int || version > kConnectorCatalogVersion) return const [];
  final entries = decoded['connectors'];
  if (entries is! List) return const [];

  final catalog = <ConnectorCatalogEntry>[];
  for (final raw in entries) {
    if (raw is! Map<String, dynamic>) continue;
    final code = raw['code'] ?? raw['id'];
    final label = raw['label'] ?? raw['name'];
    if (code is! String || code.isEmpty || label is! String || label.isEmpty) {
      continue;
    }
    final mcp = raw['mcp'];
    catalog.add(
      ConnectorCatalogEntry(
        id: raw['id'] is String ? raw['id'] as String : code,
        code: code,
        label: label,
        description: raw['description'] is String
            ? raw['description'] as String
            : '',
        imageUrl: raw['image_url'] is String ? raw['image_url'] as String : '',
        mcpUrl: mcp is Map<String, dynamic> && mcp['url'] is String
            ? mcp['url'] as String
            : '',
      ),
    );
  }
  return sortCatalog(catalog);
}

/// The backend's order first (nulls last), then alphabetically by label — so a
/// catalog with no ordering at all still lands in a stable, readable sequence
/// instead of whatever order the payload happened to arrive in.
List<ConnectorCatalogEntry> sortCatalog(List<ConnectorCatalogEntry> entries) {
  final sorted = [...entries]
    ..sort((a, b) {
      final ao = a.order;
      final bo = b.order;
      if (ao != bo) {
        if (ao == null) return 1;
        if (bo == null) return -1;
        return ao.compareTo(bo);
      }
      return a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });
  return sorted;
}

/// The catalog, from the backend when it answers and from the bundled asset
/// when it doesn't.
///
/// The fallback is not a nicety: the backend for this list doesn't exist yet,
/// and the screen has to work meanwhile. It also covers a user offline or on a
/// stale build, so it stays after the API ships.
final connectorCatalogProvider = FutureProvider<List<ConnectorCatalogEntry>>((
  ref,
) async {
  final (remote, _) = await ref.watch(connectorCatalogClientProvider).fetch();
  if (remote != null && remote.isNotEmpty) return remote;
  return ref.watch(bundledConnectorCatalogProvider.future);
});

/// The catalog shipped inside the app. A failure to load or parse reads as an
/// empty catalog — the Connectors screen still works as a plain MCP manager.
final bundledConnectorCatalogProvider =
    FutureProvider<List<ConnectorCatalogEntry>>((ref) async {
      try {
        final raw = await rootBundle.loadString(
          'assets/connectors/catalog.json',
        );
        return parseConnectorCatalog(raw);
      } on Object {
        return const [];
      }
    });
