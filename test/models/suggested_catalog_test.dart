import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/models/logic/suggested_catalog.dart';
import 'package:grid_app/infrastructure/api/model_catalog_client.dart';
import 'package:grid_app/infrastructure/api/models/model_catalog.dart';
import 'package:grid_app/infrastructure/providers.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';

CatalogModelPick _pick(String repo) => CatalogModelPick(
  repoId: repo,
  version: 'Q4_K_M',
  sizeBytes: 2000000000,
  file: '$repo.gguf',
  maxCtx: 32768,
  estTokPerSec: 10,
  pullSpec: '$repo:$repo.gguf',
  urls: const [],
);

/// A fake suggest call returning a fixed result — the network never runs.
CatalogSuggestFn _fnReturning(
  (CatalogSuggestion?, ModelCatalogError?) result,
) =>
    ({required apiUrl, required sessionToken, required device}) async => result;

ProviderContainer _container({
  String? token = 'tok-1',
  Map<String, dynamic>? device = const {'device_class': 'cpu'},
  required CatalogSuggestFn fn,
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
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('suggestedCatalogProvider', () {
    test('no session token → sign-in required (no device probe, no call)',
        () async {
      var called = false;
      final container = _container(
        token: null,
        fn: ({required apiUrl, required sessionToken, required device}) async {
          called = true;
          return (null, null);
        },
      );

      final outcome = await container.read(suggestedCatalogProvider.future);
      expect(outcome, isA<SuggestSignInRequired>());
      expect(called, isFalse); // signed-out short-circuits before the network
    });

    test('device probe failing → unavailable (falls back to offline list)',
        () async {
      final container = _container(
        device: null,
        fn: _fnReturning((null, null)),
      );
      final outcome = await container.read(suggestedCatalogProvider.future);
      expect(outcome, isA<SuggestUnavailable>());
    });

    test('ranked picks → ready, pick is the first', () async {
      final suggestion = CatalogSuggestion(
        pick: _pick('Qwen/Qwen2.5-3B-Instruct-GGUF'),
        alternatives: [_pick('meta-llama/Llama-3.2-3B-Instruct-GGUF')],
      );
      final container = _container(fn: _fnReturning((suggestion, null)));

      final outcome = await container.read(suggestedCatalogProvider.future);
      expect(outcome, isA<SuggestReady>());
      final ready = outcome as SuggestReady;
      expect(ready.pick.repoId, 'Qwen/Qwen2.5-3B-Instruct-GGUF');
      expect(ready.ranked, hasLength(2));
    });

    test('empty ranking (no-match sentinel) → no match', () async {
      final empty = CatalogSuggestion(
        pick: CatalogModelPick.fromJson(const {'repo_id': null}),
        alternatives: const [],
      );
      final container = _container(fn: _fnReturning((empty, null)));

      final outcome = await container.read(suggestedCatalogProvider.future);
      expect(outcome, isA<SuggestNoMatch>());
    });

    test('a 401 error → sign-in required, not a dead-end failure', () async {
      final container = _container(
        fn: _fnReturning((
          null,
          const ModelCatalogError('expired', statusCode: 401, sessionExpired: true),
        )),
      );
      final outcome = await container.read(suggestedCatalogProvider.future);
      expect(outcome, isA<SuggestSignInRequired>());
    });

    test('a non-auth error → unavailable, carrying the reason', () async {
      final container = _container(
        fn: _fnReturning((
          null,
          const ModelCatalogError('The catalog is warming up. Try again shortly.'),
        )),
      );
      final outcome = await container.read(suggestedCatalogProvider.future);
      expect(outcome, isA<SuggestUnavailable>());
      expect((outcome as SuggestUnavailable).reason, contains('warming up'));
    });
  });
}
