/// The caption that says which models served a turn.
///
/// Logic only, per `conventions.md §8` — the rendering has no test, but the
/// arithmetic and the wording rules do, because they are what goes wrong: a
/// percentage that does not sum to 100, or a line that changes shape halfway
/// through a turn the user is watching.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/turn_model_share.dart';

/// Identity, so the assertions read on the ids themselves.
String _plain(String id) => id;

ModelShare _share(String model, int requests) =>
    ModelShare(model: model, requests: requests);

void main() {
  group('percentages', () {
    test('always sum to exactly 100', () {
      for (final shares in [
        [_share('a', 1), _share('b', 1), _share('c', 1)],
        [_share('a', 7), _share('b', 2), _share('c', 1)],
        [_share('a', 2), _share('b', 1)],
        [_share('a', 100), _share('b', 1)],
      ]) {
        expect(
          percentages(shares).fold(0, (s, v) => s + v),
          100,
          reason: 'for $shares',
        );
      }
    });

    test('the biggest share stays the biggest after rounding', () {
      final shares = [_share('a', 5), _share('b', 4), _share('c', 1)];
      final percents = percentages(shares);
      expect(percents.first, greaterThanOrEqualTo(percents[1]));
      expect(percents[1], greaterThanOrEqualTo(percents[2]));
    });
  });

  group('modelShareLabel', () {
    test('a single model shows from its very first turn', () {
      // Waiting for a second model left the live caption blank through the
      // opening minute of a long task, which is when it is most wanted.
      expect(modelShareLabel([_share('qwen', 3)], label: _plain), 'qwen ×3');
    });

    test('a lone model is never percented, however many requests', () {
      // `100%` compares it against nothing and reads as a measurement.
      expect(modelShareLabel([_share('qwen', 40)], label: _plain), 'qwen ×40');
    });

    test('one model answering once says nothing the model name does not', () {
      expect(modelShareLabel([_share('qwen', 1)], label: _plain), isNull);
    });

    test('nothing recorded stays null so the caller keeps its own label', () {
      expect(modelShareLabel(const [], label: _plain), isNull);
    });

    test('two models percent from the first handful of requests', () {
      // No floor: a 6/2 split shows its share immediately instead of waiting
      // for ten requests before a percentage is worth showing.
      expect(
        modelShareLabel([_share('a', 6), _share('b', 2)], label: _plain),
        'a 75% · b 25%',
      );
    });

    test('at ten requests it turns to percentages', () {
      // Ten is where one request is 10%, so the first percentage shown is never
      // finer than the data behind it.
      expect(
        modelShareLabel([_share('a', 7), _share('b', 3)], label: _plain),
        'a 70% · b 30%',
      );
    });

    test('names at most three models, then counts the rest', () {
      final shares = [
        _share('a', 5),
        _share('b', 3),
        _share('c', 2),
        _share('d', 1),
        _share('e', 1),
      ];
      expect(modelShareLabel(shares, label: _plain), endsWith('+2 more'));
    });

    test('empty rows never reach the line', () {
      expect(
        modelShareLabel([_share('a', 4), _share('b', 0)], label: _plain),
        'a ×4',
      );
    });
  });

  group('modelShareDetail', () {
    test('lists every model, including the ones the footer left out', () {
      final shares = [
        _share('a', 5),
        _share('b', 3),
        _share('c', 2),
        _share('d', 1),
      ];
      final detail = modelShareDetail(shares, label: _plain);
      for (final model in ['a', 'b', 'c', 'd']) {
        expect(detail, contains(model));
      }
      expect(detail, contains('11 requests'));
    });

    test('says "1 request" rather than "1 requests"', () {
      expect(
        modelShareDetail([_share('a', 1)], label: _plain),
        contains('1 request'),
      );
    });
  });
}
