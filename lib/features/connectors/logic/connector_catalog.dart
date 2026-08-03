import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'browse_connectors_controller.dart';

/// How a catalog service is signed into.
enum ConnectorAuthMethod {
  /// The connector signs in through Grid — the app opens a browser and the
  /// account is linked. Everything the API returns today is this.
  app,

  /// The provider registers OAuth clients on demand (RFC 7591), so the app is
  /// its own client and the gateway is not involved at all: no `client_secret`
  /// held server-side, no token brokered, nothing to disconnect there.
  ///
  /// What every directory row claims. The claim is only a starting point — the
  /// probe at Connect time is what decides whether the server can actually be
  /// driven this way.
  dcr,

  /// The server asks for no credential at all. Connecting is just writing the
  /// MCP entry into the agent's config — no browser, no token, nothing stored
  /// in `tokens.json`, and nothing to expire.
  ///
  /// Same standing as [dcr]: a claim, settled by the probe at Connect time.
  open,

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

  /// Whether Connect is offered: the app has a sign-in flow it can drive for
  /// this connector, whether that runs through the gateway ([app]) or entirely
  /// on this machine ([dcr]).
  ///
  /// `mcpReady` deliberately does **not** gate this. It says the gateway has an
  /// MCP server wired up, which decides whether the *agent* gains a tool — not
  /// whether the *account* can be linked. Signing in works either way, the
  /// credential is real, and the row says "No tools yet" afterwards until the
  /// backend catches up. Withholding the button instead made connectors the
  /// gateway plainly advertises as `auth_type: app` look broken.
  bool get canConnectFromApp =>
      authMethod == ConnectorAuthMethod.app || isSelfServe;

  /// The app handles this connector end to end, without the gateway.
  ///
  /// Both routes start the same way — probe the server, then do what it says —
  /// so this is the test `connectCatalog` branches on, rather than either value
  /// on its own.
  bool get isSelfServe =>
      authMethod == ConnectorAuthMethod.dcr ||
      authMethod == ConnectorAuthMethod.open;

  /// This entry with display text filled in, for the fields the gateway left
  /// empty — today only the derived label.
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

/// The backend's order first (nulls last), then alphabetically by label — so a
/// catalog with no ordering at all still lands in a stable, readable sequence
/// instead of whatever order the payload happened to arrive in.
/// What a row sorts under: its label, or its code while it has no label.
String _sortKey(ConnectorCatalogEntry entry) =>
    (entry.label.isNotEmpty ? entry.label : entry.code).toLowerCase();

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
      // Falls back to the code when a row has no label. Sorting on an empty
      // string would leave those in payload order, so a list that looks
      // alphabetical in one build would arrive shuffled in another.
      return _sortKey(a).compareTo(_sortKey(b));
    });
  return sorted;
}

/// A display name derived from a connector's code.
///
/// Only reached when the gateway sends no `label`. Splitting on the separators
/// the codes actually use and capitalizing gets "Gmail App", "Google Calendar",
/// "Hubspot": not always the brand's own styling, but always a phrase rather
/// than an identifier.
String labelFromCode(String code) {
  final words = code
      .split(RegExp(r'[_\-\s]+'))
      .where((word) => word.isNotEmpty)
      .map((word) => word[0].toUpperCase() + word.substring(1));
  return words.isEmpty ? code : words.join(' ');
}

/// The connectors catalog: the public MCP directory, and nothing else.
///
/// **One source, by decision (Tony, 2026-08-03).** Two others used to feed this:
/// the gateway's own sixteen curated rows (`GET {gridApiUrl}/v1/grid/connectors`)
/// and a bundled list of twenty-four self-serve services. Both are gone from the
/// screen. What replaced them reaches four thousand servers with no backend of
/// ours in the path at all — the registry answers unauthenticated, and each
/// server's own authorization server handles the sign-in.
///
/// **The gateway client is still wired, and must stay.** Removing the catalog
/// call is not removing the gateway: credentials obtained through it
/// (`ConnectorTokenSource.gateway`) are renewed and revoked against it, so
/// `connector_link_controller.dart` still holds four references. Cutting those
/// would strand every connector signed in before this change — they would work
/// until their token expired and then have nowhere to go.
///
/// What this costs, plainly: connectors needing a pre-registered OAuth app —
/// Google and Slack, whose `client_secret` can only live server-side — can no
/// longer be signed into from here at all. Rows already connected keep working;
/// they come from the token store and the agent's config, not from this list.
final connectorCatalogProvider = FutureProvider<List<ConnectorCatalogEntry>>((
  ref,
) async {
  return ref.watch(directoryCatalogProvider);
});
