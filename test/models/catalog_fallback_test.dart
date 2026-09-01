import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/models/logic/catalog_fallback.dart';
import 'package:grid_app/infrastructure/api/model_catalog_client.dart';
import 'package:grid_app/infrastructure/api/models/model_catalog.dart';
import 'package:grid_app/infrastructure/logging/app_log.dart';
import 'package:grid_app/infrastructure/state/catalog_cache_store.dart';

const _body = '{"models":[{"repo_id":"Qwen/Qwen2.5-3B-Instruct-GGUF"}]}';

CatalogRead<List<CatalogListEntry>> _ok(String body) =>
    (value: parseCatalogList(body), body: body, error: null);

CatalogRead<List<CatalogListEntry>> _failed(ModelCatalogError error) =>
    (value: null, body: null, error: error);

void main() {
  late Directory dir;
  late CatalogCacheStore cache;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('catalog_fallback_test');
    cache = CatalogCacheStore(file: File('${dir.path}/catalog_cache.json'));
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Future<CatalogOutcome<List<CatalogListEntry>>> read(
    CatalogRead<List<CatalogListEntry>> result,
  ) => readCatalog<List<CatalogListEntry>>(
    cache: cache,
    log: const NoopAppLog(),
    key: 'list|https://api.test/|trending|',
    fetch: () async => result,
    parse: parseCatalogList,
  );

  group('readCatalog', () {
    test('a live answer is served as live, and saved for next time', () async {
      final outcome = await read(_ok(_body));

      expect(outcome.data, hasLength(1));
      expect(outcome.savedAt, isNull, reason: 'nothing stale to announce');
      expect(cache.read('list|https://api.test/|trending|')?.body, _body);
    });

    test(
      'a catalog that is down is answered from the saved copy, dated',
      () async {
        await read(_ok(_body));

        final outcome = await read(
          _failed(const ModelCatalogError("Couldn't reach the catalog")),
        );

        expect(outcome.data, hasLength(1));
        expect(outcome.savedAt, isNotNull);
        expect(
          outcome.error?.message,
          contains('reach'),
          reason: 'the real failure survives for the log and the retry',
        );
      },
    );

    test('a failure with nothing saved stays a failure', () async {
      final outcome = await read(
        _failed(const ModelCatalogError('The catalog is warming up.')),
      );

      expect(outcome.data, isNull);
      expect(outcome.savedAt, isNull);
      expect(outcome.error?.message, contains('warming up'));
    });

    test(
      'an expired session is not served models it must ask them to sign in for',
      () async {
        await read(_ok(_body));

        final outcome = await read(
          _failed(
            const ModelCatalogError(
              'Your session has expired. Sign in again.',
              statusCode: 401,
              sessionExpired: true,
            ),
          ),
        );

        expect(outcome.data, isNull);
        expect(outcome.savedAt, isNull);
        expect(outcome.error?.sessionExpired, isTrue);
      },
    );

    test(
      'a saved copy that no longer parses is not passed off as data',
      () async {
        cache.save('list|https://api.test/|trending|', 'was json once');

        final outcome = await read(
          _failed(const ModelCatalogError("Couldn't reach the catalog")),
        );

        expect(outcome.data, isNull);
        expect(outcome.savedAt, isNull);
      },
    );
  });

  group('savedAgoLabel', () {
    final now = DateTime(2026, 9, 1, 12);

    test('anything under a minute reads as just now', () {
      expect(
        savedAgoLabel(now.subtract(const Duration(seconds: 40)), now: now),
        'just now',
      );
    });

    test('minutes, hours and days each get their own unit', () {
      expect(
        savedAgoLabel(now.subtract(const Duration(minutes: 12)), now: now),
        '12 minutes ago',
      );
      expect(
        savedAgoLabel(now.subtract(const Duration(hours: 3)), now: now),
        '3 hours ago',
      );
      expect(
        savedAgoLabel(now.subtract(const Duration(days: 2)), now: now),
        '2 days ago',
      );
    });

    test('one of anything is singular', () {
      expect(
        savedAgoLabel(now.subtract(const Duration(hours: 1)), now: now),
        '1 hour ago',
      );
    });

    test(
      'a clock that ran backwards reads as just now, never in the future',
      () {
        expect(
          savedAgoLabel(now.add(const Duration(minutes: 5)), now: now),
          'just now',
        );
      },
    );
  });
}
