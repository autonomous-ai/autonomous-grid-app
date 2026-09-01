import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/model_catalog_client.dart';
import '../../../infrastructure/api/models/model_detail.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../../infrastructure/providers.dart';
import '../../../infrastructure/state/catalog_cache_store.dart';
import '../../auth/logic/session_controller.dart';
import 'catalog_fallback.dart';
import 'suggested_catalog.dart';

/// The per-model detail call, injectable so the provider below is testable
/// without the network.
typedef CatalogDetailFn =
    Future<CatalogRead<ModelDetail>> Function({
      required String apiUrl,
      required String sessionToken,
      required String repoId,
      Map<String, dynamic>? device,
    });

final catalogDetailFnProvider = Provider<CatalogDetailFn>(
  (ref) => ModelCatalogClient.detail,
);

/// One model's full version list, each row carrying the verdict for this
/// computer (`GET /v1/grid/catalog/{repo_id}` with the device profile).
///
/// Saved on the way through, so a catalog that goes down between opening the
/// manager and picking a model still shows the versions — and still hands
/// `grid pull` a spec to download — with `savedAt` telling the panel to say
/// where they came from.
final modelDetailProvider =
    FutureProvider.family<CatalogOutcome<ModelDetail>, String>((
      ref,
      repoId,
    ) async {
      final token = ref.watch(sessionProvider).sessionToken;
      if (token == null || token.isEmpty) {
        return (
          data: null,
          error: const ModelCatalogError(
            'Sign in to see model details.',
            sessionExpired: true,
          ),
          savedAt: null,
        );
      }

      final apiUrl = ref.watch(gridApiUrlProvider);
      final detail = ref.watch(catalogDetailFnProvider);
      // A device the CLI couldn't read is not a reason to show nothing: the
      // catalog answers without one, the versions simply arrive unjudged.
      final device = await ref.watch(deviceInfoProvider.future);

      return readCatalog<ModelDetail>(
        cache: ref.watch(catalogCacheStoreProvider),
        log: ref.read(appLogProvider),
        key: catalogDetailKey(apiUrl: apiUrl, repoId: repoId),
        fetch: () => detail(
          apiUrl: apiUrl,
          sessionToken: token,
          repoId: repoId,
          device: device,
        ),
        parse: parseModelDetail,
      );
    });
