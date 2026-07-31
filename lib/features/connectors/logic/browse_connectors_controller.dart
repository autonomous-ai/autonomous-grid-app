import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/smithery_registry_client.dart';
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
    this.page = 0,
    this.totalPages = 0,
    this.totalCount = 0,
    this.loading = false,
    this.loadingMore = false,
    this.error,
  });

  final List<SmitheryServer> servers;

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

  BrowseConnectorsState copyWith({
    List<SmitheryServer>? servers,
    String? query,
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
  Future<void> search(String query) async {
    final generation = ++_generation;
    final trimmed = query.trim();
    state = BrowseConnectorsState(query: trimmed, loading: true);

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
