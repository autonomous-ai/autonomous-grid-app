import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/state/catalog_cache_store.dart';

void main() {
  late Directory dir;
  late CatalogCacheStore store;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('catalog_cache_test');
    file = File('${dir.path}/app/catalog_cache.json');
    store = CatalogCacheStore(file: file);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  group('CatalogCacheStore', () {
    test(
      'a saved body reads back byte for byte, so it parses like a live one',
      () {
        const body = '{"models":[{"repo_id":"Qwen/Qwen2.5-3B-Instruct-GGUF"}]}';
        store.save('list|https://api.test/|trending|', body);

        final entry = store.read('list|https://api.test/|trending|');
        expect(entry?.body, body);
        expect(
          entry!.savedAt.difference(DateTime.now()).inMinutes.abs(),
          lessThan(1),
        );
      },
    );

    test('a request never answered has nothing to fall back on', () {
      expect(store.read('detail|https://api.test/|nobody/nothing'), isNull);
    });

    test('re-asking replaces the older copy rather than keeping both', () {
      store.save('k', '{"models":[]}');
      store.save('k', '{"models":[1]}');

      expect(store.read('k')?.body, '{"models":[1]}');
      final saved = jsonDecode(file.readAsStringSync()) as Map;
      expect(saved.keys, ['k']);
    });

    test('an empty body is not worth saving over what is already there', () {
      store.save('k', '{"models":[1]}');
      store.save('k', '');

      expect(store.read('k')?.body, '{"models":[1]}');
    });

    test('the file stops growing at maxEntries, oldest first', () {
      for (var i = 0; i <= CatalogCacheStore.maxEntries; i++) {
        store.save('key-$i', '{"n":$i}');
      }

      final saved = jsonDecode(file.readAsStringSync()) as Map;
      expect(saved, hasLength(CatalogCacheStore.maxEntries));
      expect(
        store.read('key-0'),
        isNull,
        reason: 'the oldest is the one to go',
      );
      expect(store.read('key-${CatalogCacheStore.maxEntries}'), isNotNull);
    });

    test('a corrupt file reads as nothing saved and still takes new saves', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('not json at all');

      expect(store.read('k'), isNull);
      store.save('k', '{"models":[]}');
      expect(store.read('k')?.body, '{"models":[]}');
    });

    test('an entry missing its timestamp is dropped, not guessed at', () {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          'k': {'body': '{"models":[]}'},
        }),
      );

      expect(store.read('k'), isNull);
    });
  });

  group('cache keys', () {
    test('two control planes never read each other saved answers', () {
      expect(
        catalogSuggestKey('https://api.test/'),
        isNot(catalogSuggestKey('https://staging.test/')),
      );
    });

    test('a ranking and a search term each make their own answer', () {
      const url = 'https://api.test/';
      final trending = catalogListKey(apiUrl: url, sort: 'trending', query: '');
      final liked = catalogListKey(apiUrl: url, sort: 'likes', query: '');
      final searched = catalogListKey(apiUrl: url, sort: '', query: 'qwen');

      expect({trending, liked, searched}, hasLength(3));
    });

    test('each model detail is kept under its own repo', () {
      const url = 'https://api.test/';
      expect(
        catalogDetailKey(apiUrl: url, repoId: 'a/b'),
        isNot(catalogDetailKey(apiUrl: url, repoId: 'a/c')),
      );
    });
  });
}
