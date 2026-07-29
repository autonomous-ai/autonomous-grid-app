import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/connector_gateway_client.dart';

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

  /// This entry with borrowed display text, used by [mergeCatalog] to dress a
  /// gateway row in the bundled catalog's label and icon.
  ///
  /// Only the three presentation fields can be replaced, and only where this
  /// entry has nothing: whatever the gateway said about state — `mcpReady`,
  /// `linkedAtServer`, `authMethod` — is carried through untouched. A merge
  /// that could overwrite those would let a stale bundled asset contradict the
  /// live backend about whether a connector can be signed into.
  ConnectorCatalogEntry withPresentation({
    String label = '',
    String description = '',
    String imageUrl = '',
  }) {
    return ConnectorCatalogEntry(
      id: id,
      code: code,
      label: this.label.isNotEmpty ? this.label : label,
      description: this.description.isNotEmpty ? this.description : description,
      imageUrl: this.imageUrl.isNotEmpty ? this.imageUrl : imageUrl,
      mcpUrl: mcpUrl,
      order: order,
      installed: installed,
      authMethod: authMethod,
      mcpReady: mcpReady,
      linkedAtServer: linkedAtServer,
      accountName: accountName,
      canRefresh: canRefresh,
    );
  }
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

/// What a row sorts under: its label, or its code while it has no label.
String _sortKey(ConnectorCatalogEntry entry) =>
    (entry.label.isNotEmpty ? entry.label : entry.code).toLowerCase();

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
      // Falls back to the code when a row has no label yet — which is every
      // gateway row before `mergeCatalog` dresses it. Sorting on an empty
      // string would leave those in payload order, so a list that looks
      // alphabetical in one build would arrive shuffled in another.
      return _sortKey(a).compareTo(_sortKey(b));
    });
  return sorted;
}

/// A display name for a connector the bundled catalog has never heard of.
///
/// The gateway's list is the one that grows — it already carries connectors no
/// bundled build knows (`amplitude`, `asana`, `hubspot`) — so the fallback has
/// to be something, and `gmail-app` set in a title is not a name anyone wrote.
/// Splitting on the separators the codes actually use and capitalizing gets
/// "Gmail App", "Google Calendar", "Hubspot": not always the brand's own
/// styling, but always a phrase rather than an identifier.
String labelFromCode(String code) {
  final words = code
      .split(RegExp(r'[_\-\s]+'))
      .where((word) => word.isNotEmpty)
      .map((word) => word[0].toUpperCase() + word.substring(1));
  return words.isEmpty ? code : words.join(' ');
}

/// Give the gateway's entries the names and marks the bundled catalog holds.
///
/// The two lists answer different questions and neither can replace the other.
/// The gateway knows *state* — which connectors exist, which are ready, which
/// this account has linked — and sends no display text at all. The bundled
/// asset knows *presentation* — real labels, blurbs, CDN icons — for the eight
/// connectors that existed when it was written, and nothing about state.
///
/// So this merges rather than choosing: every row comes from [remote] (it is
/// the authority on what exists), and [bundled] fills in only the fields the
/// gateway left empty. A gateway that later starts sending `label` wins
/// automatically, because a non-empty remote value is never overwritten.
///
/// Matching is by exact code. `gmail` and `gmail-app` are different rows on the
/// wire — one `pat`, one `app` — and guessing that they are the same service
/// would put one connector's icon on another's row.
List<ConnectorCatalogEntry> mergeCatalog({
  required List<ConnectorCatalogEntry> remote,
  required List<ConnectorCatalogEntry> bundled,
}) {
  final byCode = {for (final entry in bundled) entry.code: entry};
  return sortCatalog([
    for (final entry in remote)
      entry.withPresentation(
        label: byCode[entry.code]?.label ?? labelFromCode(entry.code),
        description: byCode[entry.code]?.description ?? '',
        imageUrl: byCode[entry.code]?.imageUrl ?? '',
      ),
  ]);
}

/// The catalog, from the gateway when it answers and from the bundled asset
/// when it doesn't.
///
/// It reads through [ConnectorGatewayClient] — the same client that runs the
/// sign-in — rather than a catalog-only client, because the two must agree on
/// what a connector *is*. A parser that skips `mcp_ready` leaves every row
/// looking unavailable while the gateway is plainly saying otherwise, and the
/// screen has no way to tell that apart from a backend with nothing ready.
///
/// The bundled fallback stays for the offline case, but it is a weaker answer
/// now: it carries labels and icons, never `mcp_ready` or `status`, so a row
/// sourced from it can be shown but not signed into.
final connectorCatalogProvider = FutureProvider<List<ConnectorCatalogEntry>>((
  ref,
) async {
  final bundled = await ref.watch(bundledConnectorCatalogProvider.future);
  final (remote, _) = await ref
      .watch(connectorGatewayClientProvider)
      .connectors();
  if (remote == null || remote.isEmpty) return bundled;
  return mergeCatalog(remote: remote, bundled: bundled);
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
