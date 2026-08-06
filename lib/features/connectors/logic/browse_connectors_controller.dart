import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/connector_gateway_client.dart';
import '../../../infrastructure/api/smithery_registry_client.dart';
import 'connector_blurb_fallback.dart';
import 'connector_catalog.dart';
import 'connector_category.dart';
import 'connector_directory_source.dart';
import 'smithery_catalog.dart';
import 'smithery_server.dart';

/// What the connector directory is showing right now.
///
/// One object rather than four providers because the states are *mutually
/// constraining*: "loading" with rows already on screen means a page is being
/// appended, and the same flag with none means the first page has not arrived.
/// Split across providers, that distinction has to be re-derived at every read,
/// and the version that forgets it renders skeletons over a list the user was
/// halfway through.
class BrowseConnectorsState {
  const BrowseConnectorsState({
    this.entries = const [],
    this.query = '',
    this.category,
    this.sort = SmitheryServerSort.mostUsed,
    this.cursor,
    this.totalCount = 0,
    this.loading = false,
    this.loadingMore = false,
    this.error,
  });

  /// The rows, already in the app's own catalog type.
  ///
  /// **Neutral on purpose, and this is what makes two sources cheap.** This
  /// used to hold `SmitheryServer`, so every consumer — the screen, the browse
  /// dialog, the catalog provider — spoke one directory's vocabulary, and
  /// changing directory meant changing all of them. `ConnectorCatalogEntry` is
  /// the type the rest of the app already uses; each source converts into it and
  /// nothing downstream can tell, or needs to, which one answered.
  final List<ConnectorCatalogEntry> entries;

  /// How [visibleEntries] is ordered. Changing this does **not** refetch.
  final SmitheryServerSort sort;

  /// The search these rows answer — not what is in the box, which may have moved
  /// on. Paging sends *this*, so appending page 2 of an old search onto a new
  /// one is impossible.
  ///
  /// The user's words only. The category's own term is **not** folded in here:
  /// this is what the search box shows, and rewriting it would put words in the
  /// box the user never typed. The two are combined at request time — see
  /// [searchTerms].
  final String query;

  /// The subject pill in force, or null for the whole directory.
  ///
  /// Kept beside [query] rather than merged into it because they are undone
  /// separately: clearing the search box must not clear the category, and
  /// deselecting the category must not empty the box.
  final ConnectorCategory? category;

  /// What actually goes to a directory that searches remotely.
  String get searchTerms => categorySearchTerms(category, query);

  /// Where the next page starts, or null when there is none.
  ///
  /// A string so one field serves both sources: Smithery pages by number and
  /// stringifies it, a flat source leaves it null. Adding a second paging
  /// concept would mean every reader deciding which of the two to trust.
  final String? cursor;

  /// How many rows match, across every page. Zero when the source didn't say.
  final int totalCount;

  /// The first page is in flight — the list is replaced, so the screen shows
  /// skeletons.
  final bool loading;

  /// A further page is in flight — the list stays, and only the footer changes.
  final bool loadingMore;

  final String? error;

  /// More rows can be asked for. Always false on a source that isn't paged.
  bool get hasMore =>
      kConnectorDirectorySource.isPaged && cursor != null && cursor!.isNotEmpty;

  /// Nothing to show, and not because we are still looking.
  bool get isEmpty => entries.isEmpty && !loading && error == null;

  /// What the screen draws: the fetched rows in the chosen order.
  ///
  /// Derived rather than stored, so [entries] and this can never disagree — the
  /// bug available in the stored version is a sort applied to page one and
  /// silently not to page two.
  ///
  /// The order is left alone on a source with no popularity to sort by: the
  /// gateway hands back a list its own backend curated, and reshuffling that by
  /// a `useCount` that is zero for every row would replace a deliberate order
  /// with an arbitrary one.
  List<ConnectorCatalogEntry> get visibleEntries =>
      kConnectorDirectorySource.hasPopularity ? sort.applyTo(entries) : entries;

  BrowseConnectorsState copyWith({
    List<ConnectorCatalogEntry>? entries,
    String? query,
    ConnectorCategory? category,
    SmitheryServerSort? sort,
    String? cursor,
    int? totalCount,
    bool? loading,
    bool? loadingMore,
    String? error,
    bool clearError = false,
    bool clearCategory = false,
    bool clearCursor = false,
  }) => BrowseConnectorsState(
    entries: entries ?? this.entries,
    query: query ?? this.query,
    // Same trap as `error` below, and as `archivedAt` before it: `?? this.x`
    // cannot express "set this to null", so deselecting the pill would silently
    // keep filtering by the category the user just turned off.
    category: clearCategory ? null : (category ?? this.category),
    sort: sort ?? this.sort,
    // The end of the list is spelled `null`, so reaching it needs the same
    // explicit flag for the same reason.
    cursor: clearCursor ? null : (cursor ?? this.cursor),
    totalCount: totalCount ?? this.totalCount,
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    error: clearError ? null : (error ?? this.error),
  );
}

/// Ordering a list of catalog rows.
///
/// On the enum's own extension rather than as a method, because the enum
/// belongs to the Smithery model and this orders the neutral type every source
/// produces. The two sort keys it needs — `useCount` and `label` — exist on
/// both.
extension SmitheryServerSortOnEntries on SmitheryServerSort {
  /// [entries], ordered. Never sorts in place — the caller's list is state.
  List<ConnectorCatalogEntry> applyTo(List<ConnectorCatalogEntry> entries) =>
      switch (this) {
        SmitheryServerSort.relevance => entries,
        SmitheryServerSort.mostUsed => [
          ...entries,
        ]..sort((a, b) => b.useCount.compareTo(a.useCount)),
        SmitheryServerSort.name =>
          [...entries]..sort(
            (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
          ),
      };
}

/// Loading the connector directory, whichever one is switched on.
///
/// Deliberately not an `AsyncNotifier<List<…>>` like the other controllers on
/// this screen. Those own a *whole* list that is re-read on every change; this
/// one can accumulate pages, and an `AsyncLoading` on load-more would blank rows
/// the user is reading. The screen states here are richer than `AsyncValue` can
/// say, so the state object says them.
class BrowseConnectorsController extends Notifier<BrowseConnectorsState> {
  /// Rows per request, for a source that pages.
  ///
  /// The registry caps browsing at **500 rows** whatever this is — 50 gives 10
  /// pages, 24 gave 21, and page 11 (respectively 22) comes back as an empty
  /// array either way. So this trades requests against latency, not against
  /// reach. Measured 2026-07-31. Unused by a flat source.
  static const int pageSize = 50;

  /// Counts every reload so a slow answer to an abandoned query cannot land.
  ///
  /// Typing "no" then "notion" fires two requests; without this the first can
  /// resolve last and leave the list showing results for a query the box no
  /// longer contains. Compared at every await boundary.
  int _generation = 0;

  @override
  BrowseConnectorsState build() =>
      const BrowseConnectorsState(sort: SmitheryServerSort.mostUsed);

  /// Load (or reload) the first page for [query].
  Future<void> search(String query) async {
    // Category survives a search: it is a standing narrowing of the directory,
    // not part of what was typed, and clearing it on a keystroke would undo a
    // choice the user can still see selected in the bar.
    await _load(query: query.trim(), category: state.category);
  }

  /// Narrow the directory to one subject, or to none.
  Future<void> setCategory(ConnectorCategory? category) async {
    if (category == state.category) return;
    await _load(query: state.query, category: category);
  }

  /// Reorder what is already loaded. **No refetch** — neither source sorts on
  /// the server.
  void setSort(SmitheryServerSort sort) {
    if (sort == state.sort) return;
    state = state.copyWith(sort: sort);
  }

  /// The one path that replaces the list, so a search and a category change
  /// cannot drift apart in how they reset state.
  Future<void> _load({
    required String query,
    required ConnectorCategory? category,
  }) async {
    final generation = ++_generation;
    // Sort survives — it is a view preference, not part of the query, and
    // resetting it on every keystroke would fight the user.
    state = BrowseConnectorsState(
      query: query,
      category: category,
      sort: state.sort,
      loading: true,
    );

    final result = await _fetch(search: state.searchTerms);
    if (generation != _generation) return;

    if (result.error != null) {
      state = state.copyWith(loading: false, error: result.error);
      return;
    }
    state = state.copyWith(
      entries: result.entries,
      cursor: result.cursor,
      clearCursor: result.cursor == null,
      totalCount: result.totalCount,
      loading: false,
      clearError: true,
    );
  }

  /// Append the next page — and keep going until it is worth having appended.
  ///
  /// **A paged registry repeats itself, heavily.** Measured 2026-08-03 over ten
  /// pages: 500 rows fetched, **208 unique** — 58% duplicates — and the new rows
  /// per page decay 50, 50, 24, 18, 16, 12, 8, 10, 9, 11. One fetch per scroll
  /// therefore stops adding anything a user can see long before the pages run
  /// out, which is what "infinite scroll doesn't work" looked like.
  ///
  /// Returns immediately on a source that isn't paged — [BrowseConnectorsState.hasMore]
  /// is false there, so the scroll listener can call this on every frame.
  Future<void> loadMore() async {
    final current = state;
    if (!current.hasMore || current.loading || current.loadingMore) return;

    final generation = _generation;
    state = current.copyWith(loadingMore: true, clearError: true);

    var added = 0;
    for (var fetch = 0; fetch < _maxFetchesPerScroll; fetch++) {
      if (!state.hasMore) break;

      final result = await _fetch(
        search: state.searchTerms,
        cursor: state.cursor,
      );
      // Checked after every await, not once: this loop spans several round
      // trips, and a search started midway through must not have pages of the
      // old one appended underneath it.
      if (generation != _generation) return;

      if (result.error != null) {
        state = state.copyWith(loadingMore: false, error: result.error);
        return;
      }

      // Deduplicated on the way in. Pages are a snapshot of a directory that
      // keeps being written to — and, measured, one that serves the same row on
      // several pages regardless.
      final seen = {for (final entry in state.entries) entry.id};
      final fresh = [
        for (final entry in result.entries)
          if (seen.add(entry.id)) entry,
      ];
      added += fresh.length;

      state = state.copyWith(
        entries: [...state.entries, ...fresh],
        cursor: result.cursor,
        clearCursor: result.cursor == null,
        totalCount: result.totalCount,
      );
      if (added >= _minimumNewRows) break;
    }
    state = state.copyWith(loadingMore: false);
  }

  /// Enough new rows that the scroll visibly moved. Roughly two grid rows.
  static const int _minimumNewRows = 6;

  /// The ceiling on requests one scroll may spend chasing them.
  static const int _maxFetchesPerScroll = 3;

  /// Ask whichever directory is switched on.
  Future<_DirectoryResult> _fetch({required String search, String? cursor}) =>
      switch (kConnectorDirectorySource) {
        ConnectorDirectorySource.gateway => _fetchGateway(),
        ConnectorDirectorySource.smithery => _fetchSmithery(
          search: search,
          cursor: cursor,
        ),
      };

  /// Autonomous's own curated list — one request, the whole catalog.
  ///
  /// [search] is not sent and no page is asked for: the response *is* every row
  /// the backend offers, so filtering happens on screen and there is no second
  /// page to fetch. Measured 2026-08-05: 12 rows, 5.6 KB.
  Future<_DirectoryResult> _fetchGateway() async {
    final (entries, error) = await ref
        .read(connectorGatewayClientProvider)
        .connectors();
    if (entries == null) {
      // The gateway's own sentence, not a generic one: "Not signed in." is the
      // failure a user can act on, and browsing this directory genuinely does
      // require a session.
      return _DirectoryResult.failed(
        error?.message ?? "Couldn't load the connectors.",
      );
    }
    return _DirectoryResult(
      entries: [
        // Called unconditionally, not only for the rows missing something:
        // `withPresentation` fills empty fields and nothing else. Measured
        // 2026-08-05, only 4 of the 12 rows carry a description of their own,
        // and the bundled blurbs cover the other 8 exactly — so between them
        // every row gets a sentence.
        for (final entry in entries)
          entry.withPresentation(
            label: labelFromCode(entry.code),
            description: connectorBlurbFallback(entry.code),
          ),
      ],
      // No next page and no total beyond what arrived: this is the whole list.
      cursor: null,
      totalCount: entries.length,
    );
  }

  /// The public registry — paged, searched on the server.
  Future<_DirectoryResult> _fetchSmithery({
    required String search,
    String? cursor,
  }) async {
    final page = int.tryParse(cursor ?? '1') ?? 1;
    final (result, error) = await ref
        .read(smitheryRegistryClientProvider)
        .servers(page: page, pageSize: pageSize, query: search);
    if (result == null) return _DirectoryResult.failed(error);

    final next = result.page < result.totalPages ? '${result.page + 1}' : null;
    return _DirectoryResult(
      entries: smitheryCatalogEntries(result.servers),
      cursor: next,
      totalCount: result.totalCount,
    );
  }
}

/// One directory answer, whichever source gave it.
class _DirectoryResult {
  const _DirectoryResult({
    required this.entries,
    required this.cursor,
    required this.totalCount,
  }) : error = null;

  const _DirectoryResult.failed(this.error)
    : entries = const [],
      cursor = null,
      totalCount = 0;

  final List<ConnectorCatalogEntry> entries;
  final String? cursor;
  final int totalCount;
  final String? error;
}

final browseConnectorsProvider =
    NotifierProvider<BrowseConnectorsController, BrowseConnectorsState>(
      BrowseConnectorsController.new,
    );

/// The directory rows the Connectors screen offers, as catalog entries.
///
/// **Never throws and never blocks the rest of the screen.** A directory that is
/// down, rate-limiting or answering nonsense yields an empty list, and the
/// screen is then exactly the screen it was before this existed.
///
/// Synchronous on purpose. As a `FutureProvider` this mapped an already-loaded
/// list through an `async` body, so every page and every sort flipped it to
/// `AsyncLoading` and back — a whole extra round of rebuilds for a computation
/// that never awaits anything. That churn is half of what made the list blink
/// when it reached the bottom.
final directoryCatalogProvider = Provider<List<ConnectorCatalogEntry>>((ref) {
  return ref.watch(browseConnectorsProvider).visibleEntries;
});

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
