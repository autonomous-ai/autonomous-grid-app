import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/connectors/logic/browse_connectors_controller.dart';
import 'package:grid_app/features/connectors/logic/smithery_server.dart';
import 'package:grid_app/infrastructure/api/smithery_registry_client.dart';

/// A registry that records what it was asked and answers what it was told to.
class _FakeRegistry implements SmitheryRegistryClient {
  _FakeRegistry();

  final List<String> queries = [];
  final List<Set<SmitheryFilter>> filterSets = [];
  final List<int> pages = [];

  /// Answers, in order. A `null` entry is a failure.
  List<SmitheryPage?> replies = [];
  String error = 'boom';
  int _call = 0;

  @override
  Duration get timeout => const Duration(seconds: 1);

  @override
  Future<(SmitheryPage?, String?)> servers({
    int page = 1,
    int pageSize = 50,
    String query = '',
    Set<SmitheryFilter> filters = const {},
  }) async {
    queries.add(query);
    filterSets.add(filters);
    pages.add(page);
    final reply = _call < replies.length ? replies[_call] : null;
    _call++;
    return reply == null ? (null, error) : (reply, null);
  }
}

SmitheryServer _server(
  String name, {
  int useCount = 0,
  bool verified = false,
  bool managed = false,
}) => SmitheryServer(
  qualifiedName: name,
  displayName: name.toUpperCase(),
  remote: true,
  deployed: true,
  useCount: useCount,
  verified: verified,
  bySmithery: managed,
);

SmitheryPage _page(
  List<SmitheryServer> servers, {
  int page = 1,
  int totalPages = 1,
}) => SmitheryPage(
  servers: servers,
  page: page,
  totalPages: totalPages,
  totalCount: servers.length,
);

void main() {
  late _FakeRegistry registry;
  late ProviderContainer container;

  setUp(() {
    registry = _FakeRegistry();
    container = ProviderContainer(
      overrides: [smitheryRegistryClientProvider.overrideWithValue(registry)],
    );
  });
  tearDown(() => container.dispose());

  BrowseConnectorsController notifier() =>
      container.read(browseConnectorsProvider.notifier);
  BrowseConnectorsState state() => container.read(browseConnectorsProvider);

  test('smithery-managed is on before anything is asked', () async {
    // Four thousand servers anyone can publish to is not the set to open a
    // settings screen on — and `verified` is the wrong narrowing, because the
    // servers people recognise carry the *managed* mark instead.
    expect(state().filters, {SmitheryFilter.smitheryManaged});
  });

  test('the filter narrows here — the registry is never asked', () async {
    // `is:verified` excludes Smithery's own first-party servers: measured, it
    // answers 50/50 verified and 0/50 bySmithery, so gmail (60,499 uses) is
    // absent from its first 200 results. Read off the row instead.
    registry.replies = [
      _page([_server('plain'), _server('vetted', managed: true)]),
    ];

    await notifier().search('');

    expect(state().visibleServers.map((s) => s.qualifiedName), ['vetted']);
    // Both are kept; only the view of them is narrowed.
    expect(state().servers.length, 2);
  });

  test('toggling the filter costs no request', () async {
    registry.replies = [
      _page([_server('plain'), _server('vetted', managed: true)]),
    ];
    await notifier().search('');
    final requests = registry.pages.length;

    notifier().toggleFilter(SmitheryFilter.smitheryManaged);
    expect(state().filters, isEmpty);
    expect(state().visibleServers.length, 2, reason: 'nothing narrows it now');

    notifier().toggleFilter(SmitheryFilter.smitheryManaged);
    expect(state().filters, {SmitheryFilter.smitheryManaged});
    expect(state().visibleServers.length, 1);
    expect(registry.pages.length, requests, reason: 'no refetch either way');
  });

  test('a filter change keeps the pages already loaded', () async {
    registry.replies = [
      _page([_server('a', managed: true)], totalPages: 2),
      _page([_server('b')], page: 2, totalPages: 2),
    ];

    await notifier().search('');
    await notifier().loadMore();
    expect(state().servers.length, 2);

    notifier().toggleFilter(SmitheryFilter.smitheryManaged);

    // Two pages of scrolling are not thrown away for a view preference.
    expect(state().servers.length, 2);
    expect(state().page, 2);
  });

  test('sort reorders without asking the registry again', () async {
    registry.replies = [
      _page([
        _server('low', useCount: 1, managed: true),
        _server('high', useCount: 99, managed: true),
      ]),
    ];
    await notifier().search('');
    final callsBefore = registry.pages.length;

    // Most used is the default, so the switch that proves anything is away from
    // it and back.
    expect(state().visibleServers.map((s) => s.qualifiedName), ['high', 'low']);
    notifier().setSort(SmitheryServerSort.relevance);

    expect(registry.pages.length, callsBefore, reason: 'no refetch');
    expect(state().visibleServers.map((s) => s.qualifiedName), ['low', 'high']);
    // The fetched order is untouched, so relevance restores exactly what the
    // registry sent.
    expect(state().servers.map((s) => s.qualifiedName), ['low', 'high']);
  });

  test('sort survives a search; filters survive too', () async {
    registry.replies = [
      _page([_server('a')]),
      _page([_server('b')]),
    ];

    notifier().setSort(SmitheryServerSort.name);
    await notifier().search('notion');

    expect(state().sort, SmitheryServerSort.name);
    // The selection survives a search even though the registry will not honour
    // it — that is what `filtersNarrowedHere` then acts on.
    expect(state().filters, {SmitheryFilter.smitheryManaged});
  });

  test('a search reaches the whole directory, shortlist set aside', () async {
    // The plain listing is a shortlist — seventeen servers Smithery runs, out of
    // four thousand anyone can publish to. A search is the opposite request: the
    // user named the thing they want, and answering "email" with Gmail alone
    // because the other matches are community-run is refusing to look.
    registry.replies = [
      _page([_server('plain'), _server('vetted', managed: true)]),
    ];

    await notifier().search('mail');

    expect(state().visibleServers.map((s) => s.qualifiedName), [
      'plain',
      'vetted',
    ]);
    // The selection is untouched — clearing the box restores the shortlist.
    expect(state().filters, {SmitheryFilter.smitheryManaged});
  });

  test('the shortlist test reads the row, not the registry', () {
    const plain = SmitheryServer(qualifiedName: 'p', displayName: 'P');
    const vetted = SmitheryServer(
      qualifiedName: 'v',
      displayName: 'V',
      verified: true,
    );
    expect(SmitheryFilter.verified.keeps(plain), isFalse);
    expect(SmitheryFilter.verified.keeps(vetted), isTrue);
    expect(SmitheryFilter.smitheryManaged.keeps(plain), isFalse);
  });

  test('load more appends, dedupes, and keeps the original query', () async {
    registry.replies = [
      _page([_server('a'), _server('b')], totalPages: 2),
      // `b` arrives twice: pages are a snapshot of a directory that keeps being
      // written to, so a row on the boundary shifts down and repeats.
      _page([_server('b'), _server('c')], page: 2, totalPages: 2),
    ];

    await notifier().search('exa');
    await notifier().loadMore();

    expect(state().servers.map((s) => s.qualifiedName), ['a', 'b', 'c']);
    expect(registry.queries, ['exa', 'exa']);
    expect(state().hasMore, isFalse);
  });

  test('a failed page keeps the rows already on screen', () async {
    registry.replies = [
      _page([_server('a')], totalPages: 2),
      null,
    ];

    await notifier().search('');
    await notifier().loadMore();

    expect(state().servers.map((s) => s.qualifiedName), ['a']);
    expect(state().error, 'boom');
    expect(state().loadingMore, isFalse);
  });

  test('a successful reload clears the error that preceded it', () async {
    registry.replies = [
      null,
      _page([_server('a')]),
    ];

    await notifier().search('');
    expect(state().error, isNotNull);

    await notifier().search('');
    expect(state().error, isNull);
  });
}
