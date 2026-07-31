import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/connector_gateway_client.dart';
import 'connector_blurb_fallback.dart';
import 'self_serve_catalog.dart';

/// How a catalog service is signed into.
enum ConnectorAuthMethod {
  /// The connector signs in through Grid — the app opens a browser and the
  /// account is linked. Everything the API returns today is this.
  app,

  /// The provider registers OAuth clients on demand (RFC 7591), so the app is
  /// its own client and the gateway is not involved at all: no `client_secret`
  /// held server-side, no token brokered, nothing to disconnect there.
  ///
  /// Comes from the bundled list in `self_serve_catalog.dart`, and from a
  /// gateway row that says `auth_type: "dcr"`. Either way the claim is only a
  /// starting point — the probe at Connect time is what decides whether the
  /// server can actually be driven this way.
  dcr,

  /// The server asks for no credential at all. Connecting is just writing the
  /// MCP entry into the agent's config — no browser, no token, nothing stored
  /// in `tokens.json`, and nothing to expire.
  ///
  /// Same standing as [dcr]: a claim from the bundled list, settled by the
  /// probe at Connect time.
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

/// The connectors catalog: the gateway's list, and nothing else.
///
/// There is no bundled fallback. One used to ship in the app, and it was a
/// liability rather than a safety net — it knew eight connectors while the
/// gateway serves sixteen, carried no `mcp_ready` or `status`, and so produced
/// rows that looked real and could not be signed into. A catalog the backend
/// hasn't confirmed is worse than an empty screen, which at least says the
/// truth: we could not reach the grid.
///
/// Presentation is the backend's too. Rows arrive with `label`, `description`
/// and `image_url` filled in; when one is missing the row degrades on its own —
/// a name derived from the code, a glyph instead of a logo, no description line
/// at all.
///
/// The one thing added to the gateway's list is [selfServeCatalogProvider] —
/// connectors the app signs into without it. Those are not a fallback and do
/// not soften the paragraph above: they carry no backend state to be stale
/// about, they never displace a gateway row ([mergeCatalog]), and they keep
/// working while the grid is unreachable because nothing in their flow touches
/// it. An empty gateway is still an empty gateway; it just no longer takes
/// Canva down with it.
final connectorCatalogProvider = FutureProvider<List<ConnectorCatalogEntry>>((
  ref,
) async {
  final (remote, _) = await ref
      .watch(connectorGatewayClientProvider)
      .connectors();
  final selfServe = await ref.watch(selfServeCatalogProvider.future);
  return mergeCatalog(
    gateway: [
      // Called unconditionally, not only for the rows missing something:
      // `withPresentation` fills empty fields and nothing else, so the guard the
      // label used to carry was a second copy of a rule already stated there —
      // and it applied to the label alone, which is how the description came to
      // have no fallback at all.
      //
      // `remote ?? []` rather than an early return: a gateway we could not
      // reach still leaves the self-serve rows, which never needed it.
      for (final entry in remote ?? const <ConnectorCatalogEntry>[])
        entry.withPresentation(
          label: labelFromCode(entry.code),
          description: connectorBlurbFallback(entry.code),
        ),
    ],
    selfServe: selfServe,
  );
});
