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
}) => SmitheryServer(
  qualifiedName: name,
  displayName: name.toUpperCase(),
  remote: true,
  deployed: true,
  useCount: useCount,
  verified: verified,
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

  test('verified is on before anything is asked', () async {
    // Four thousand servers anyone can publish to is not the set to open a
    // settings screen on.
    expect(state().filters, {SmitheryFilter.verified});
  });

  test('a filter is sent to the registry, not applied locally', () async {
    // The registry caps browsing at 500 rows, so a local test would search only
    // what has been fetched and present that as the whole answer.
    registry.replies = [
      _page([_server('a')]),
    ];

    await notifier().search('');

    expect(registry.filterSets.single, {SmitheryFilter.verified});
  });

  test(
    'toggling the default filter clears it, and again restores it',
    () async {
      registry.replies = [
        _page([_server('a')]),
        _page([_server('a'), _server('b')]),
      ];

      await notifier().toggleFilter(SmitheryFilter.verified);
      expect(state().filters, isEmpty);
      expect(registry.filterSets.last, isEmpty);

      await notifier().toggleFilter(SmitheryFilter.verified);
      expect(state().filters, {SmitheryFilter.verified});
    },
  );

  test('a filter change reloads from page one', () async {
    registry.replies = [
      _page([_server('a')], totalPages: 3),
      _page([_server('b')], page: 2, totalPages: 3),
      _page([_server('c')], totalPages: 3),
    ];

    await notifier().search('');
    await notifier().loadMore();
    expect(state().servers.length, 2);

    await notifier().toggleFilter(SmitheryFilter.verified);

    expect(registry.pages.last, 1);
    // The accumulated pages belong to the old filter and cannot be kept.
    expect(state().servers.map((s) => s.qualifiedName), ['c']);
  });

  test('sort reorders without asking the registry again', () async {
    registry.replies = [
      _page([_server('low', useCount: 1), _server('high', useCount: 99)]),
    ];
    await notifier().search('');
    final callsBefore = registry.pages.length;

    notifier().setSort(SmitheryServerSort.mostUsed);

    expect(registry.pages.length, callsBefore, reason: 'no refetch');
    expect(state().visibleServers.map((s) => s.qualifiedName), ['high', 'low']);
    // The fetched order is untouched, so switching back restores exactly what
    // the registry sent.
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
    expect(state().filters, {SmitheryFilter.verified});
  });

  test('a search narrows verified here, since the registry will not', () async {
    // Measured 2026-08-03: `notion is:verified` returns riskmodels, mem0,
    // thoughtbox — every row verified, not one of them Notion. So the text goes
    // alone and the filter is applied to what comes back.
    registry.replies = [
      _page([_server('plain'), _server('vetted', verified: true)]),
    ];

    await notifier().search('notion');

    // The controller still passes the selection down; dropping the token when a
    // search is running belongs to `SmitheryRegistryClient`, which this fake
    // stands in for.
    expect(state().filtersNarrowedHere, isTrue);
    expect(state().visibleServers.map((s) => s.qualifiedName), ['vetted']);
    // The fetched rows are untouched — clearing the search restores them.
    expect(state().servers.length, 2);
  });

  test('with no search running the registry does the narrowing', () async {
    registry.replies = [
      _page([_server('a'), _server('b', verified: true)]),
    ];
    await notifier().search('');

    expect(state().filtersNarrowedHere, isFalse);
    // Both kept: the registry already returned only what the token allowed.
    expect(state().visibleServers.length, 2);
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
