import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/composio_catalog_client.dart';
import '../../../infrastructure/api/smithery_registry_client.dart';
import 'composio_catalog.dart';
import 'composio_toolkit.dart';
import 'connector_catalog.dart';
import 'connector_category.dart';
import 'smithery_catalog.dart';

/// Which directory answered.
///
/// Worth naming because the two behave differently in ways a reader of the
/// state will otherwise have to infer: Composio rows sign in through the
/// gateway and carry no address, Smithery rows sign themselves in and carry
/// one. It is also how [BrowseConnectorsController] reports that it is running
/// on the fallback rather than the intended source.
enum DirectorySource { composio, smithery }

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
    this.sort = ComposioToolkitSort.mostUsed,
    this.source = DirectorySource.composio,
    this.cursor,
    this.totalCount = 0,
    this.loading = false,
    this.loadingMore = false,
    this.error,
  });

  /// The rows, already converted to the app's own catalog type.
  ///
  /// **Neutral on purpose, and this is what makes a second source cheap.** The
  /// state used to hold `SmitheryServer`, so every consumer — the screen, the
  /// browse dialog, the catalog provider — spoke one vendor's vocabulary, and
  /// changing directory meant changing all of them. `ConnectorCatalogEntry` is
  /// the type the rest of the app already uses; each source converts into it and
  /// nothing downstream can tell, or needs to, which one answered.
  final List<ConnectorCatalogEntry> entries;

  /// How the catalog is ordered. **Refetches**, unlike the previous directory's
  /// sort — see [BrowseConnectorsController.setSort].
  final ComposioToolkitSort sort;

  /// Which directory produced [entries].
  final DirectorySource source;

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

  /// What actually goes to the directory: the user's words and the category's.
  String get searchTerms => categorySearchTerms(category, query);

  /// Where the next page starts, or null when there is none.
  ///
  /// **A cursor, not a page number.** Composio hands back an opaque
  /// `next_cursor` and null means the end, so there is no page arithmetic to get
  /// wrong. The Smithery fallback has page numbers instead; it stringifies them
  /// into this field rather than adding a second paging concept nobody reading
  /// the state would know which of to trust.
  final String? cursor;

  /// How many rows match, across every page. Zero when the source didn't say.
  final int totalCount;

  /// The first page is in flight — the list is replaced, so the screen shows
  /// skeletons.
  final bool loading;

  /// A further page is in flight — the list stays, and only the footer changes.
  final bool loadingMore;

  final String? error;

  bool get hasMore => cursor != null && cursor!.isNotEmpty;

  /// Nothing to show, and not because we are still looking.
  bool get isEmpty => entries.isEmpty && !loading && error == null;

  BrowseConnectorsState copyWith({
    List<ConnectorCatalogEntry>? entries,
    String? query,
    ConnectorCategory? category,
    ComposioToolkitSort? sort,
    DirectorySource? source,
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
    source: source ?? this.source,
    // The end of the list is spelled `null`, so reaching it needs the same
    // explicit flag for the same reason.
    cursor: clearCursor ? null : (cursor ?? this.cursor),
    totalCount: totalCount ?? this.totalCount,
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    error: clearError ? null : (error ?? this.error),
  );
}

/// Paging over the connector directory.
///
/// **Composio is the source; Smithery is the fallback.** The app's half of that
/// migration can ship before the backend's — see [_fetch] — so a build that
/// meets a backend without the proxy route keeps listing connectors from the
/// previous directory instead of showing an empty screen. Remove [_fetchSmithery]
/// and its branch once the route is live everywhere.
///
/// Deliberately not an `AsyncNotifier<List<…>>` like the other controllers on
/// this screen. Those own a *whole* list that is re-read on every change; this
/// one accumulates pages, and an `AsyncLoading` on load-more would blank rows
/// the user is reading. The screen states here are richer than `AsyncValue` can
/// say, so the state object says them.
class BrowseConnectorsController extends Notifier<BrowseConnectorsState> {
  /// Rows per request. Composio allows up to 1,000; 50 fills several screens
  /// without making the first paint wait on rows nobody has scrolled to.
  static const int pageSize = 50;

  /// Counts every reload so a slow answer to an abandoned query cannot land.
  ///
  /// Typing "no" then "notion" fires two requests; without this the first can
  /// resolve last and leave the list showing results for a query the box no
  /// longer contains. Compared at every await boundary.
  int _generation = 0;

  /// Sort stated here rather than left to the constructor's default.
  ///
  /// It *was* the default and the screen still opened on the wrong one, which a
  /// default buried in a parameter list is very good at hiding. Naming it at the
  /// one place someone looks for "what does this start as" costs a line.
  @override
  BrowseConnectorsState build() =>
      const BrowseConnectorsState(sort: ComposioToolkitSort.mostUsed);

  /// Load (or reload) the first page for [query].
  Future<void> search(String query) async {
    // Category survives a search: it is a standing narrowing of the directory,
    // not part of what was typed, and clearing it on a keystroke would undo a
    // choice the user can still see selected in the bar.
    await _load(
      query: query.trim(),
      category: state.category,
      sort: state.sort,
    );
  }

  /// Narrow the directory to one subject, or to none.
  Future<void> setCategory(ConnectorCategory? category) async {
    if (category == state.category) return;
    await _load(query: state.query, category: category, sort: state.sort);
  }

  /// Reorder the catalog.
  ///
  /// **Refetches, which the previous directory's sort did not.** Smithery had no
  /// sort parameter — every spelling of one was measured and returned the
  /// identical page — so ordering was done locally over whatever rows happened
  /// to be loaded, which quietly answered "most used of the fifty on screen"
  /// when the control asks "most used". Composio sorts the whole catalog, so the
  /// honest implementation asks it again.
  Future<void> setSort(ComposioToolkitSort sort) async {
    if (sort == state.sort) return;
    await _load(query: state.query, category: state.category, sort: sort);
  }

  /// The one path that replaces the list, so search, category and sort cannot
  /// drift apart in how they reset state.
  Future<void> _load({
    required String query,
    required ConnectorCategory? category,
    required ComposioToolkitSort sort,
  }) async {
    final generation = ++_generation;
    state = BrowseConnectorsState(
      query: query,
      category: category,
      sort: sort,
      loading: true,
    );

    final result = await _fetch(search: state.searchTerms, sort: sort);
    if (generation != _generation) return;

    if (result.error != null) {
      state = state.copyWith(loading: false, error: result.error);
      return;
    }
    state = state.copyWith(
      entries: result.entries,
      source: result.source,
      cursor: result.cursor,
      clearCursor: result.cursor == null,
      totalCount: result.totalCount,
      loading: false,
      clearError: true,
    );
  }

  /// Append the next page.
  Future<void> loadMore() async {
    final current = state;
    if (!current.hasMore || current.loading || current.loadingMore) return;

    final generation = _generation;
    state = current.copyWith(loadingMore: true, clearError: true);

    final result = await _fetch(
      search: current.searchTerms,
      sort: current.sort,
      cursor: current.cursor,
      source: current.source,
    );
    if (generation != _generation) return;

    if (result.error != null) {
      state = state.copyWith(loadingMore: false, error: result.error);
      return;
    }

    // Deduplicated on the way in. A directory is a snapshot of something that
    // keeps being written to, and the previous one was measured serving the same
    // row on several pages — 500 fetched for 208 unique. Composio's cursor
    // paging should not repeat itself, but a list that grows by rows the user
    // can already see is the kind of bug that reads as "paging is broken", and
    // the guard costs one set.
    final seen = {for (final entry in state.entries) entry.id};
    final fresh = [
      for (final entry in result.entries)
        if (seen.add(entry.id)) entry,
    ];

    state = state.copyWith(
      entries: [...state.entries, ...fresh],
      cursor: result.cursor,
      clearCursor: result.cursor == null,
      totalCount: result.totalCount,
      loadingMore: false,
    );
  }

  /// Ask the directory, falling back when the backend has no route yet.
  ///
  /// [source] pins the fallback decision for a *continuation*: once a list is
  /// being served by Smithery, page two has to come from Smithery too — its
  /// cursor means nothing to Composio, and a mixed list would page into rows the
  /// first page was never filtered against.
  Future<_DirectoryResult> _fetch({
    required String search,
    required ComposioToolkitSort sort,
    String? cursor,
    DirectorySource? source,
  }) async {
    if (source == DirectorySource.smithery) {
      return _fetchSmithery(search: search, cursor: cursor);
    }

    final (page, error) = await ref
        .read(composioCatalogClientProvider)
        .toolkits(search: search, limit: pageSize, cursor: cursor, sort: sort);
    if (page != null) {
      return _DirectoryResult(
        entries: composioCatalogEntries(page.toolkits),
        cursor: page.nextCursor,
        totalCount: page.totalItems,
        source: DirectorySource.composio,
      );
    }
    // Two failures fall through, and only two: the backend having no such route
    // yet, and there being no session to ask with. Everything else — a rate
    // limit, a 500, a shape nobody understands — is Composio genuinely
    // answering, and quietly serving another directory's rows instead would
    // hide it.
    //
    // **The signed-out case is a regression guard, not a nicety.** Browsing
    // needs no account today, because the directory it replaces is public. Left
    // out, this migration would have met a signed-out user with an empty screen
    // and a sign-in demand for something that had never required one.
    final canFallBack =
        ComposioCatalogClient.isNotDeployed(error) ||
        ComposioCatalogClient.isNotSignedIn(error);
    if (!canFallBack) return _DirectoryResult.failed(error);
    return _fetchSmithery(search: search, cursor: cursor);
  }

  /// The previous directory, kept until the Composio route ships everywhere.
  ///
  /// Its rows stay `dcr` and keep their own address, because that is what they
  /// are: these servers sign themselves in and the gateway has never heard of
  /// them. Converting them into Composio-shaped rows would hand them to the
  /// gateway path and every one of them would fail at the far end.
  Future<_DirectoryResult> _fetchSmithery({
    required String search,
    String? cursor,
  }) async {
    // Smithery pages by number; the cursor carries it as text so the state has
    // one paging field rather than two that must agree.
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
      source: DirectorySource.smithery,
    );
  }
}

/// One directory answer, whichever source gave it.
class _DirectoryResult {
  const _DirectoryResult({
    required this.entries,
    required this.cursor,
    required this.totalCount,
    required this.source,
  }) : error = null;

  const _DirectoryResult.failed(this.error)
    : entries = const [],
      cursor = null,
      totalCount = 0,
      source = DirectorySource.composio;

  final List<ConnectorCatalogEntry> entries;
  final String? cursor;
  final int totalCount;
  final DirectorySource source;
  final String? error;
}

final browseConnectorsProvider =
    NotifierProvider<BrowseConnectorsController, BrowseConnectorsState>(
      BrowseConnectorsController.new,
    );

/// The directory rows the Connectors screen offers, as catalog entries.
///
/// **Never throws and never blocks the rest of the list.** A directory that is
/// down, rate-limiting or answering nonsense yields an empty list, and the
/// screen is then exactly the screen it was before this existed. The alternative
/// — letting a directory failure propagate — would take working connectors
/// offline over a third party's bad afternoon.
///
/// Synchronous on purpose. As a `FutureProvider` this mapped an already-loaded
/// list through an `async` body, so every page and every sort flipped it to
/// `AsyncLoading` and back — a whole extra round of rebuilds for a computation
/// that never awaits anything. That churn is half of what made the list blink
/// when it reached the bottom. Now that the state holds entries directly there
/// is nothing left to map at all.
final directoryCatalogProvider = Provider<List<ConnectorCatalogEntry>>((ref) {
  return ref.watch(browseConnectorsProvider).entries;
});
