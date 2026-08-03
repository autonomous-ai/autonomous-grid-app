import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/smithery_registry_client.dart';
import 'connector_catalog.dart';
import 'smithery_catalog.dart';
import 'smithery_server.dart';

/// What the browse dialog is showing right now.
///
/// One object rather than four providers because the states are *mutually
/// constraining*: "loading" with rows already on screen means a page is being
/// appended, and the same flag with none means the first page has not arrived.
/// Split across providers, that distinction has to be re-derived at every read,
/// and the version that forgets it renders skeletons over a list the user was
/// halfway through.
class BrowseConnectorsState {
  const BrowseConnectorsState({
    this.servers = const [],
    this.query = '',
    this.sort = SmitheryServerSort.mostUsed,
    this.page = 0,
    this.totalPages = 0,
    this.totalCount = 0,
    this.loading = false,
    this.loadingMore = false,
    this.error,
  });

  /// The rows as fetched, in the registry's own order.
  ///
  /// [visibleServers] is what the screen draws. Keeping the fetched order here
  /// means switching sort never needs a refetch, and switching *back* to
  /// relevance restores exactly what the registry sent rather than an
  /// approximation of it.
  final List<SmitheryServer> servers;

  /// How [visibleServers] is ordered. Changing this does **not** refetch.
  final SmitheryServerSort sort;

  /// The search this list answers — not what is in the box, which may have moved
  /// on. Load more sends *this*, so appending page 2 of an old search onto a new
  /// one is impossible.
  final String query;

  /// The last page successfully appended. Zero means nothing has loaded.
  final int page;

  final int totalPages;
  final int totalCount;

  /// The first page of a search is in flight — the list is replaced, so the
  /// dialog shows skeletons.
  final bool loading;

  /// A further page is in flight — the list stays, and only the footer changes.
  final bool loadingMore;

  final String? error;

  bool get hasMore => page > 0 && page < totalPages;

  /// Nothing to show, and not because we are still looking.
  bool get isEmpty => servers.isEmpty && !loading && error == null;

  /// What the screen draws: the fetched rows, narrowed and ordered.
  ///
  /// Derived rather than stored, so [servers] and this can never disagree — the
  /// bug available in the stored version is a sort applied to page one and
  /// silently not to page two.
  /// What the screen draws: the fetched rows in the chosen order.
  ///
  /// **Nothing is filtered out, and that is a reversal.** A shortlist of the
  /// seventeen Smithery-managed servers was the default, and it broke paging in
  /// a way that read as a bug: all seventeen are on page one, so scrolling to
  /// the end fetched fifty more rows of which **none** passed the filter and the
  /// list did not grow. Infinite scroll cannot work over a set that is already
  /// complete.
  ///
  /// Ordering does the work instead. `mostUsed` — the default — opens on
  /// `jina` (76,715), `googlesheets` (63,663), `gmail` (60,499) and `brave`
  /// (60,204), which is the quality-first list the filter was reaching for, and
  /// scrolling carries on into the rest of the directory instead of stopping
  /// dead.
  List<SmitheryServer> get visibleServers => sort.apply(servers);

  BrowseConnectorsState copyWith({
    List<SmitheryServer>? servers,
    String? query,
    SmitheryServerSort? sort,
    int? page,
    int? totalPages,
    int? totalCount,
    bool? loading,
    bool? loadingMore,
    String? error,
    bool clearError = false,
  }) => BrowseConnectorsState(
    servers: servers ?? this.servers,
    query: query ?? this.query,
    sort: sort ?? this.sort,
    page: page ?? this.page,
    totalPages: totalPages ?? this.totalPages,
    totalCount: totalCount ?? this.totalCount,
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    // `?? this.error` cannot clear a field, which is the same trap `archivedAt`
    // hit: without the flag a successful reload would keep showing the failure
    // that preceded it.
    error: clearError ? null : (error ?? this.error),
  );
}

/// Paging over the public MCP directory.
///
/// Deliberately not an `AsyncNotifier<List<…>>` like the other controllers on
/// this screen. Those own a *whole* list that is re-read on every change; this
/// one accumulates pages, and an `AsyncLoading` on load-more would blank rows
/// the user is reading. The screen states here are richer than `AsyncValue` can
/// say, so the state object says them.
class BrowseConnectorsController extends Notifier<BrowseConnectorsState> {
  /// Rows per request.
  ///
  /// The registry caps browsing at **500 rows** whatever this is — 50 gives 10
  /// pages, 24 gave 21, and page 11 (respectively 22) comes back as an empty
  /// array either way. So this trades requests against latency, not against
  /// reach: 50 is ten fetches to the ceiling instead of twenty-one, and the
  /// scroll rarely catches up with the list. Measured 2026-07-31.
  static const int pageSize = 50;

  /// Counts every search so a slow answer to an abandoned query cannot land.
  ///
  /// Typing "no" then "notion" fires two requests; without this the first can
  /// resolve last and leave the list showing results for a query the box no
  /// longer contains. Compared at every await boundary.
  int _generation = 0;

  @override
  BrowseConnectorsState build() => const BrowseConnectorsState();

  /// Load (or reload) the first page for [query].
  ///
  Future<void> search(String query) async {
    final generation = ++_generation;
    final trimmed = query.trim();
    // Sort survives a search — it is a view preference, not part of the query,
    // and resetting it on every keystroke would fight the user.
    state = BrowseConnectorsState(
      query: trimmed,
      sort: state.sort,
      loading: true,
    );

    final (page, error) = await ref
        .read(smitheryRegistryClientProvider)
        .servers(page: 1, pageSize: pageSize, query: trimmed);
    if (generation != _generation) return;

    if (page == null) {
      state = state.copyWith(loading: false, error: error);
      return;
    }
    state = state.copyWith(
      servers: page.servers,
      page: page.page,
      totalPages: page.totalPages,
      totalCount: page.totalCount,
      loading: false,
      clearError: true,
    );
  }

  /// Reorder what is already loaded. **No refetch**, because the registry has no
  /// sort of its own to ask for.
  void setSort(SmitheryServerSort sort) {
    if (sort == state.sort) return;
    state = state.copyWith(sort: sort);
  }

  /// Append the next page of the *current* search.
  Future<void> loadMore() async {
    final current = state;
    if (!current.hasMore || current.loading || current.loadingMore) return;

    final generation = _generation;
    state = current.copyWith(loadingMore: true, clearError: true);

    final (page, error) = await ref
        .read(smitheryRegistryClientProvider)
        .servers(
          page: current.page + 1,
          pageSize: pageSize,
          query: current.query,
        );
    if (generation != _generation) return;

    if (page == null) {
      state = state.copyWith(loadingMore: false, error: error);
      return;
    }
    // Deduplicated on the way in. Pages are a snapshot of a directory that keeps
    // being written to, so a server added between two requests shifts everything
    // down one and the row on the boundary arrives twice — visible to the user
    // as a duplicate, and a duplicate key if it ever reached a keyed list.
    final seen = {for (final server in state.servers) server.qualifiedName};
    state = state.copyWith(
      servers: [
        ...state.servers,
        for (final server in page.servers)
          if (seen.add(server.qualifiedName)) server,
      ],
      page: page.page,
      totalPages: page.totalPages,
      totalCount: page.totalCount,
      loadingMore: false,
    );
  }
}

final browseConnectorsProvider =
    NotifierProvider<BrowseConnectorsController, BrowseConnectorsState>(
      BrowseConnectorsController.new,
    );

/// The directory rows the Connectors screen offers, as catalog entries.
///
/// **Never throws and never blocks the gateway's list.** A registry that is
/// down, rate-limiting or answering nonsense yields an empty list, and the
/// screen is then exactly the screen it was before this existed. The alternative
/// — letting a directory failure propagate — would take sixteen working gateway
/// connectors offline over a third party's bad afternoon, which is the same
/// trade the catalog has always made: an offer that cannot be fetched is a
/// missing row, not a broken screen.
/// Synchronous on purpose. As a `FutureProvider` this mapped an already-loaded
/// list through an `async` body, so every page and every sort flipped it to
/// `AsyncLoading` and back — a whole extra round of rebuilds for a computation
/// that never awaits anything. That churn is half of what made the list blink
/// when it reached the bottom.
final directoryCatalogProvider = Provider<List<ConnectorCatalogEntry>>((ref) {
  final state = ref.watch(browseConnectorsProvider);
  return smitheryCatalogEntries(state.visibleServers);
});
