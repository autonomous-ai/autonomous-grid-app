import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/api/relay_web_client.dart';

void main() {
  group(
    'the relay\'s web replies — the wire the scripts and the app share',
    () {
      test('hits are read title/url/excerpt, blanks tolerated, and a body that '
          'is not a search reply is null rather than "no results"', () {
        expect(
          webSearchHitsFromJson({
            'results': [
              {'title': ' A ', 'url': 'https://a', 'excerpt': 'aa'},
              {'url': 'https://b'},
            ],
          }),
          const [
            (title: 'A', url: 'https://a', excerpt: 'aa'),
            (title: '', url: 'https://b', excerpt: ''),
          ],
        );
        expect(webSearchHitsFromJson({'results': const []}), isEmpty);
        expect(webSearchHitsFromJson({'detail': 'nope'}), isNull);
        expect(webSearchHitsFromJson('text'), isNull);
      });

      test('a page is the first result\'s text; a page that refused is a '
          'refusal, never a blank page', () {
        expect(
          webPageFromJson({
            'results': [
              {'title': 'T', 'text': ' body ', 'status': 'ok'},
            ],
          }),
          (title: 'T', text: 'body'),
        );
        expect(
          () => webPageFromJson({
            'results': [
              {'status': 'error', 'error': 'blocked by robots'},
            ],
          }),
          throwsA(
            isA<RelayWebRefused>().having(
              (r) => r.message,
              'message',
              contains('blocked by robots'),
            ),
          ),
        );
        expect(webPageFromJson({'results': const []}), isNull);
        expect(webPageFromJson(null), isNull);
      });
    },
  );

  group('relayWebRefusal — one sentence, and whether to try again', () {
    test('an old relay and a refused credential are not worth retrying, and '
        'each says what to do instead', () {
      final old = relayWebRefusal(404, null, action: 'search the web');
      expect(old.retryable, isFalse);
      expect(old.message, contains('cannot search the web yet'));
      for (final status in [401, 403]) {
        final refused = relayWebRefusal(status, null, action: 'x');
        expect(refused.retryable, isFalse);
        expect(refused.message, contains('sign out'));
      }
    });

    test('the relay\'s own sentence wins when it sent one, and a spent daily '
        'allowance is the one 429 that will not lift this turn', () {
      final vendor = relayWebRefusal(429, {'detail': 'busy'}, action: 'x');
      expect(vendor.message, 'busy');
      expect(vendor.retryable, isTrue);

      final spent = relayWebRefusal(429, {
        'detail': 'spent',
        'code': kRelayWebAllowanceCode,
      }, action: 'x');
      expect(spent.retryable, isFalse);

      final down = relayWebRefusal(503, null, action: 'x');
      expect(down.retryable, isFalse);
      expect(down.message, contains('HTTP 503'));
    });
  });
}
