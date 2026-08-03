import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connector_catalog.dart';
import 'favicon_url.dart';

/// The bundled list of services this app can sign into on its own.
///
/// Each one's authorization server registers clients on demand (RFC 7591), so
/// the entire sign-in runs here — the app registers itself, drives PKCE in the
/// browser, and files the token in the master store. The gateway brokers
/// nothing and never holds the credential. That is [ConnectorAuthMethod.dcr],
/// the same path the Add custom dialog already takes for a URL the user types;
/// this list only saves them the typing.
///
/// **Why a bundled list is allowed here when a bundled catalog is not.**
/// [connectorCatalogProvider] says plainly that there is no bundled fallback,
/// and the reason still holds: an entry claiming to be a *gateway* connector
/// carries state only the gateway knows — `mcp_ready`, `status` — so a stale
/// copy shipped in the binary produces rows that look real and cannot be signed
/// into. None of that applies to an entry on this list. It has no server-side
/// state to go stale, because every fact the sign-in needs is discovered at
/// Connect time by probing the server itself. These are *additional* rows,
/// never a substitute for the gateway's, and [mergeCatalog] is what makes sure
/// they can never contradict one.
///
/// The corollary is that they survive a gateway outage, and should: nothing in
/// their flow goes through it, so a user who cannot reach the grid can still
/// connect one.
///
/// The list is data rather than Dart because it is closer to a config file than
/// to code — the field names are the gateway's own wire shape, so moving a row
/// from here to the backend is a copy rather than a translation.
const String kSelfServeCatalogAsset = 'assets/connectors/self_serve.json';

/// The bundle the list is read from. Overridable so a test hands over a string
/// instead of reaching into the real asset bundle.
final selfServeBundleProvider = Provider<AssetBundle>((ref) => rootBundle);

/// The self-serve entries, or an empty list if the asset can't be read.
///
/// Empty is the right failure: these rows are a convenience over the Add custom
/// dialog, which still works. Throwing here would take the *gateway's* catalog
/// down with it — [connectorCatalogProvider] awaits this — and lose sixteen
/// working connectors over one malformed bundled file.
final selfServeCatalogProvider = FutureProvider<List<ConnectorCatalogEntry>>((
  ref,
) async {
  try {
    return parseSelfServeCatalog(
      await ref
          .watch(selfServeBundleProvider)
          .loadString(kSelfServeCatalogAsset),
    );
  } on Object {
    return const [];
  }
});

/// Read the bundled list. Visible for testing, and pure so a test needs no
/// bundle at all.
///
/// Anything unusable is skipped rather than failing the file: one bad row must
/// not cost the others. A row with no `mcp_url` is exactly that — there is no
/// server to probe, so Connect would have nothing to do.
List<ConnectorCatalogEntry> parseSelfServeCatalog(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const [];
  }
  if (decoded is! Map<String, dynamic>) return const [];
  final list = decoded['connectors'];
  if (list is! List) return const [];

  final entries = <ConnectorCatalogEntry>[];
  for (final entry in list) {
    if (entry is! Map<String, dynamic>) continue;
    final code = entry['code'];
    final mcpUrl = entry['mcp_url'];
    if (code is! String || code.isEmpty) continue;
    if (mcpUrl is! String || mcpUrl.isEmpty) continue;

    final label = entry['label'];
    final image = entry['image_url'];
    // `dcr` is the default because it is what most of this list is. An unknown
    // value lands there too rather than dropping the row — it still gets
    // probed, and the probe is what actually decides.
    final auth = entry['auth'] == 'open'
        ? ConnectorAuthMethod.open
        : ConnectorAuthMethod.dcr;
    entries.add(
      ConnectorCatalogEntry(
        id: code,
        code: code,
        label: label is String && label.isNotEmpty
            ? label
            : labelFromCode(code),
        description: entry['description'] is String
            ? entry['description'] as String
            : '',
        // Derived from the server's host when the file doesn't say, so a new
        // row needs two fields rather than three.
        //
        // Never left empty, which is the part that matters: `Connector.imageUrl`
        // only falls back to a favicon for a row that already has a *server* —
        // an available row takes the catalog's `image_url` verbatim — so an
        // entry with no mark would show a grey glyph under Available and the
        // brand's logo under Connected, reading as two different services.
        imageUrl: image is String && image.isNotEmpty
            ? image
            : faviconUrl(mcpUrl),
        mcpUrl: mcpUrl,
        authMethod: auth,
        // True, and truthfully so: this asks whether there is an MCP server to
        // call once signed in, and `mcp_url` is that server.
        //
        // Every other gateway-shaped field is left at its default, which is
        // also the honest answer — `installed`, `linkedAtServer`, `accountName`
        // and `canRefresh` all describe something the gateway knows about a
        // user's account, and it knows nothing about these. `linkedAtServer` is
        // the one worth naming: `Connector.needsSignInHere` reads it, and a
        // true there would put "connected to your account, but not on this
        // computer" under a row no account was ever linked to.
        mcpReady: true,
      ),
    );
  }
  return entries;
}

/// The gateway's catalog with the self-serve entries added under it.
///
/// **A gateway row always wins.** When the backend starts publishing one of
/// these — with its own logo, blurb and account status — that row replaces the
/// bundled one, and nothing here has to be edited for the handover to happen.
/// This rule is what keeps a bundled entry from ever contradicting the live
/// backend, which is the whole objection to bundling anything.
///
/// Sorting is left to [sortCatalog], so a self-serve entry lands wherever its
/// label puts it rather than being pinned to the end of the list.
List<ConnectorCatalogEntry> mergeCatalog({
  required List<ConnectorCatalogEntry> gateway,
  required List<ConnectorCatalogEntry> selfServe,
  List<ConnectorCatalogEntry> directory = const [],
}) {
  // Precedence, most authoritative first: the gateway vouches for a row and can
  // broker its sign-in; a bundled self-serve row was chosen by hand; a directory
  // row is whatever the public registry happens to hold. A `code` clash is
  // resolved by the earlier source, so the day the backend starts serving
  // `notion` the community `notion` steps aside with no file to edit.
  final claimed = {for (final entry in gateway) entry.code};
  final curated = [
    for (final entry in selfServe)
      if (claimed.add(entry.code)) entry,
  ];
  return sortCatalog([
    ...gateway,
    ...curated,
    for (final entry in directory)
      if (claimed.add(entry.code)) entry,
  ]);
}
