import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/model_catalog_client.dart';
import '../../../infrastructure/api/models/model_catalog.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../../infrastructure/providers.dart';
import '../../../infrastructure/state/catalog_cache_store.dart';
import '../../auth/logic/session_controller.dart';
import 'catalog_fallback.dart';

/// What the sidebar is asking the catalog for: a search term, a ranking, or
/// both. A record so the family keys by value — `(sort: '', query: 'qwen')` and
/// `(sort: 'likes', query: 'qwen')` are two different requests, each cached.
///
/// [sort] empty means "don't pin a ranking": the sidebar sends no `sort` at all
/// while the user is typing, and only attaches one once they pick from the sort
/// menu.
typedef CatalogListArgs = ({String sort, String query});

/// The list call, injectable for the same reason as [CatalogSuggestFn] — the
/// provider below is testable without the network.
typedef CatalogListFn =
    Future<CatalogRead<List<CatalogListEntry>>> Function({
      required String apiUrl,
      required String sessionToken,
      String? sort,
      String? query,
      int pageSize,
    });

final catalogListFnProvider = Provider<CatalogListFn>(
  (ref) => ModelCatalogClient.list,
);

/// `POST /v1/grid/catalog` in list mode — the catalog's models filtered by
/// [CatalogListArgs.query] and ranked by [CatalogListArgs.sort]. Used by the
/// Models sidebar's search box and its Trending / Most liked / Newest modes
/// (the CLI `grid catalog` fallback has no such fields).
///
/// `data` is null when the user isn't signed in, or when the call failed with
/// nothing saved for these arguments; `savedAt` marks the answers that came off
/// disk because the catalog was unreachable.
final catalogListProvider =
    FutureProvider.family<
      CatalogOutcome<List<CatalogListEntry>>,
      CatalogListArgs
    >((ref, args) async {
      final token = ref.watch(sessionProvider).sessionToken;
      if (token == null || token.isEmpty) {
        return (data: null, error: null, savedAt: null);
      }
      final apiUrl = ref.watch(gridApiUrlProvider);
      final list = ref.watch(catalogListFnProvider);
      return readCatalog<List<CatalogListEntry>>(
        cache: ref.watch(catalogCacheStoreProvider),
        log: ref.read(appLogProvider),
        key: catalogListKey(apiUrl: apiUrl, sort: args.sort, query: args.query),
        fetch: () => list(
          apiUrl: apiUrl,
          sessionToken: token,
          sort: args.sort.isEmpty ? null : args.sort,
          query: args.query.isEmpty ? null : args.query,
        ),
        parse: parseCatalogList,
      );
    });
