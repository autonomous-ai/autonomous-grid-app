import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/models/logic/suggested_catalog.dart';
import 'package:grid_app/infrastructure/api/model_catalog_client.dart';
import 'package:grid_app/infrastructure/api/models/model_catalog.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/catalog_cache_store.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';

/// A suggest body in the shape the API sends, so the fallback path parses what
/// it would really have saved.
const _savedBody =
    '{"mode":"suggest","models":[{"repo_id":"Qwen/Qwen2.5-3B-Instruct-GGUF",'
    '"version":"Q4_K_M","size":2000000000,"file":"qwen2.5-3b-q4_k_m.gguf",'
    '"pull_spec":"Qwen/Qwen2.5-3B-Instruct-GGUF:qwen2.5-3b-q4_k_m.gguf"}]}';

CatalogModelPick _pick(String repo) => CatalogModelPick(
  repoId: repo,
  version: 'Q4_K_M',
  sizeBytes: 2000000000,
  file: '$repo.gguf',
  maxCtx: 32768,
  estTokPerSec: 10,
  createdAt: DateTime.now(),
  downloads: 0,
  likes: 0,
  paramsB: 7.0,
  arch: {'architecture': 'qwen2'},
  format: 'GGUF',
  pullSpec: '$repo:$repo.gguf',
  urls: const [],
);

/// A fake suggest call returning a fixed result — the network never runs.
CatalogSuggestFn _fnReturning(CatalogRead<CatalogSuggestion> result) =>
    ({required apiUrl, required sessionToken, required device}) async => result;

CatalogSuggestFn _fnSucceeding(CatalogSuggestion suggestion, {String? body}) =>
    _fnReturning((value: suggestion, body: body ?? _savedBody, error: null));

CatalogSuggestFn _fnFailing(ModelCatalogError error) =>
    _fnReturning((value: null, body: null, error: error));

ProviderContainer _container({
  String? token = 'tok-1',
  Map<String, dynamic>? device = const {'device_class': 'cpu'},
  required CatalogSuggestFn fn,
  required CatalogCacheStore cache,
}) {
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWithValue(
        token == null
            ? CredentialsFile.empty
            : CredentialsFile(networks: const [], sessionToken: token),
      ),
      deviceInfoProvider.overrideWith((ref) async => device),
      gridApiUrlProvider.overrideWithValue('https://api.test/'),
      catalogSuggestFnProvider.overrideWithValue(fn),
      catalogCacheStoreProvider.overrideWithValue(cache),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  late Directory dir;
  late CatalogCacheStore cache;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('suggested_catalog_test');
    cache = CatalogCacheStore(file: File('${dir.path}/catalog_cache.json'));
  });

  tearDown(() => dir.deleteSync(recursive: true));

  group('suggestedCatalogProvider', () {
    test(
      'no session token → sign-in required (no device probe, no call)',
      () async {
        var called = false;
        final container = _container(
          cache: cache,
          token: null,
          fn:
              ({
                required apiUrl,
                required sessionToken,
                required device,
              }) async {
                called = true;
                return (value: null, body: null, error: null);
              },
        );

        final outcome = await container.read(suggestedCatalogProvider.future);
        expect(outcome, isA<SuggestSignInRequired>());
        expect(called, isFalse); // signed-out short-circuits before the network
      },
    );

    test(
      'device probe failing → unavailable (falls back to offline list)',
      () async {
        final container = _container(
          cache: cache,
          device: null,
          fn: _fnReturning((value: null, body: null, error: null)),
        );
        final outcome = await container.read(suggestedCatalogProvider.future);
        expect(outcome, isA<SuggestUnavailable>());
      },
    );

    test('ranked models → ready, best-first', () async {
      final suggestion = CatalogSuggestion(
        models: [
          _pick('Qwen/Qwen2.5-3B-Instruct-GGUF'),
          _pick('meta-llama/Llama-3.2-3B-Instruct-GGUF'),
        ],
      );
      final container = _container(cache: cache, fn: _fnSucceeding(suggestion));

      final outcome = await container.read(suggestedCatalogProvider.future);
      expect(outcome, isA<SuggestReady>());
      final ready = outcome as SuggestReady;
      expect(ready.ranked, hasLength(2));
      expect(ready.ranked.first.repoId, 'Qwen/Qwen2.5-3B-Instruct-GGUF');
      expect(ready.savedAt, isNull, reason: 'this came off the wire');
    });

    test('empty models list → no match', () async {
      final empty = CatalogSuggestion(models: const []);
      final container = _container(
        cache: cache,
        fn: _fnSucceeding(empty, body: '{"mode":"suggest","models":[]}'),
      );

      final outcome = await container.read(suggestedCatalogProvider.future);
      expect(outcome, isA<SuggestNoMatch>());
    });

    test('a 401 error → sign-in required, not a dead-end failure', () async {
      final container = _container(
        cache: cache,
        fn: _fnFailing(
          const ModelCatalogError(
            'expired',
            statusCode: 401,
            sessionExpired: true,
          ),
        ),
      );
      final outcome = await container.read(suggestedCatalogProvider.future);
      expect(outcome, isA<SuggestSignInRequired>());
    });

    test('a non-auth error → unavailable, carrying the reason', () async {
      final container = _container(
        cache: cache,
        fn: _fnFailing(
          const ModelCatalogError(
            'The catalog is warming up. Try again shortly.',
          ),
        ),
      );
      final outcome = await container.read(suggestedCatalogProvider.future);
      expect(outcome, isA<SuggestUnavailable>());
      expect((outcome as SuggestUnavailable).reason, contains('warming up'));
    });

    test(
      'a catalog that goes down still suggests what it suggested before, dated',
      () async {
        cache.save(catalogSuggestKey('https://api.test/'), _savedBody);
        final container = _container(
          cache: cache,
          fn: _fnFailing(
            const ModelCatalogError("Couldn't reach the catalog: offline"),
          ),
        );

        final outcome = await container.read(suggestedCatalogProvider.future);
        expect(outcome, isA<SuggestReady>());
        final ready = outcome as SuggestReady;
        expect(ready.ranked.single.repoId, 'Qwen/Qwen2.5-3B-Instruct-GGUF');
        expect(
          ready.savedAt,
          isNotNull,
          reason: 'the section has to say these are saved, not fresh',
        );
      },
    );

    test('a good answer is what gets saved for that outage', () async {
      final suggestion = CatalogSuggestion(
        models: [_pick('Qwen/Qwen2.5-3B-Instruct-GGUF')],
      );
      final container = _container(cache: cache, fn: _fnSucceeding(suggestion));

      await container.read(suggestedCatalogProvider.future);

      expect(
        cache.read(catalogSuggestKey('https://api.test/'))?.body,
        _savedBody,
      );
    });
  });
}
