import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/composio_catalog_client.dart';
import '../../../infrastructure/api/smithery_registry_client.dart';
import 'composio_catalog.dart';
import 'connector_catalog.dart';
import 'smithery_catalog.dart';

/// Looks up the directory entry for a connector that is signed in but absent
/// from whatever page the browser is showing.
///
/// **Why a connected connector can have no entry at all.** The catalog is a page
/// of *search results* — fifty rows, ordered by use count — and a connector the
/// user signed in to months ago is in it only while it happens to rank. Measured
/// on this machine 2026-08-04: of eleven signed-in connectors, **three** were
/// missing from the default page — `developer-6vi7/tani`,
/// `frontier-signal/newsletter` and `info-07of/property-finance-mcp`. With no
/// entry to join to, those rows lost their logo and their description and fell
/// back to the generic link glyph, which is exactly how they were reported.
///
/// `seenCatalogEntriesProvider` covers the case where an entry *was* on screen
/// once and has since scrolled out of the query. It cannot cover this one:
/// nothing was ever seen, so there is nothing to remember. The answer has to be
/// fetched.
///
/// One request per missing connector, and only for the missing ones — a machine
/// whose connectors all rank highly issues none at all.
class ConnectedCatalogLookup {
  const ConnectedCatalogLookup(this._composio, this._smithery);

  final ComposioCatalogClient _composio;
  final SmitheryRegistryClient _smithery;

  /// The entry for [connectorId], or null when no directory knows it.
  ///
  /// **Composio answers this by name, which the previous directory could not.**
  /// A Composio connector id *is* the toolkit slug, so this is a single lookup
  /// with a definite answer. Smithery had no such endpoint — every
  /// `/servers/<name>` variant answered 404 — so its branch below still has to
  /// search for the words in the id and match exactly.
  Future<ConnectorCatalogEntry?> entryFor(String connectorId) async {
    final id = connectorId.trim();
    if (id.isEmpty) return null;

    final (toolkit, error) = await _composio.toolkit(id);
    if (toolkit != null) return composioCatalogEntry(toolkit);
    // Only "cannot ask" falls through to the old directory — no route yet, or
    // no session to ask with. A Composio that answered "no such toolkit" has
    // answered, and putting the same name to a different registry would attach
    // another service's brand to this row.
    final canFallBack =
        ComposioCatalogClient.isNotDeployed(error) ||
        ComposioCatalogClient.isNotSignedIn(error);
    if (!canFallBack) return null;

    return _smitheryEntryFor(id);
  }

  /// The previous directory, kept while the Composio route ships.
  Future<ConnectorCatalogEntry?> _smitheryEntryFor(String connectorId) async {
    // The id's separators are also its word boundaries, and the registry's
    // search is word-based: `developer-6vi7-tani` finds nothing, `developer
    // 6vi7 tani` finds it.
    final terms = connectorId.replaceAll('-', ' ').trim();
    if (terms.isEmpty) return null;

    final (page, _) = await _smithery.servers(pageSize: 8, query: terms);
    if (page == null) return null;

    for (final server in page.servers) {
      if (server.suggestedName == connectorId) {
        return smitheryCatalogEntry(server);
      }
    }
    // Found nothing that is definitely this server. A near miss is worse than
    // no answer: the row keeps its plain glyph rather than borrowing someone
    // else's brand.
    return null;
  }
}

final connectedCatalogLookupProvider = Provider<ConnectedCatalogLookup>(
  (ref) => ConnectedCatalogLookup(
    ref.watch(composioCatalogClientProvider),
    ref.watch(smitheryRegistryClientProvider),
  ),
);

/// Directory entries fetched for connected connectors the page never showed.
///
/// **[fill] is called from a provider that this one feeds, so it has to be a
/// no-op unless there is genuinely new work.** `connectorsProvider` watches this
/// and asks it to fill on every build; publishing unconditionally would rebuild
/// that provider, which would ask again, forever. Two guards prevent it: nothing
/// is fetched unless an id is missing from *both* what the page can describe and
/// what has already been fetched, and nothing is published when the fetch turns
/// up empty. A connector the registry has never heard of is therefore asked for
/// once per session, not once per frame.
///
/// Failures are silent by design: this is an *enrichment*. A row without an
/// entry still works, still shows its name, and still disconnects; it just draws
/// the generic glyph. Reporting a network error for that would be louder than
/// the problem.
class MissingCatalogEntries
    extends AsyncNotifier<Map<String, ConnectorCatalogEntry>> {
  @override
  Future<Map<String, ConnectorCatalogEntry>> build() async => const {};

  /// Fetch entries for [ids] that are not already known.
  ///
  /// [known] is what the page and the session's memory can already answer, so
  /// the common case — every connector currently on screen — costs nothing.
  /// Ids already asked about, whether or not the registry had an answer.
  ///
  /// **The failures matter more than the successes here.** A success lands in
  /// `state` and is its own record; a miss leaves nothing behind, so without
  /// this an id the registry does not know would be re-fetched on every rebuild
  /// of `connectorsProvider` — a request per frame for a row that will never
  /// have a logo. Hand-added servers, which are not in the directory at all, are
  /// exactly that case.
  final _asked = <String>{};

  /// Whether a fetch is running, so overlapping rebuilds queue behind it rather
  /// than issuing the same requests again.
  bool _busy = false;

  Future<void> fill(Set<String> ids, Set<String> known) async {
    if (_busy) return;
    final missing = ids.difference(known).difference(_asked);
    if (missing.isEmpty) return;

    _busy = true;
    // Marked before the awaits, not after: a rebuild landing mid-fetch must see
    // these as already handled.
    _asked.addAll(missing);

    final lookup = ref.read(connectedCatalogLookupProvider);
    final found = <String, ConnectorCatalogEntry>{};
    try {
      // Sequential, not parallel. These are background enrichments for rows
      // that are already usable, and a burst of eleven simultaneous requests to
      // a public directory is a worse neighbour than eleven spread out.
      for (final id in missing) {
        final entry = await lookup.entryFor(id);
        if (entry != null) found[id] = entry;
      }
    } finally {
      _busy = false;
    }
    // Nothing found is not nothing learned — `_asked` remembers it — but
    // publishing an unchanged map would rebuild every listener for no reason.
    if (found.isEmpty) return;
    state = AsyncData({...?state.value, ...found});
  }
}

final missingCatalogEntriesProvider =
    AsyncNotifierProvider<
      MissingCatalogEntries,
      Map<String, ConnectorCatalogEntry>
    >(MissingCatalogEntries.new);
