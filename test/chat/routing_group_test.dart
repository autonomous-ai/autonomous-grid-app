// test/chat/routing_group_test.dart
import 'package:grid_app/features/chat/logic/routing_group.dart';
import 'package:test/test.dart';

void main() {
  group('RoutingGroup.toModelField', () {
    test('dynamic brute force is the plain slash string', () {
      final g = RoutingGroup(mode: RoutingMode.bruteForce, isFixed: false);
      expect(g.toModelField(), 'auto/brute_force');
    });

    test('dynamic judge loop is the plain slash string', () {
      final g = RoutingGroup(mode: RoutingMode.judgeLoop, isFixed: false);
      expect(g.toModelField(), 'auto/judge_loop');
    });

    test('fixed brute force is a JSON string naming the models', () {
      final g = RoutingGroup(
        mode: RoutingMode.bruteForce,
        isFixed: true,
        models: const ['a', 'b', 'c'],
      );
      expect(g.toModelField(), '{"mode":"brute_force","models":["a","b","c"]}');
    });

    test('fixed judge loop is a JSON string naming worker and judge', () {
      final g = RoutingGroup(
        mode: RoutingMode.judgeLoop,
        isFixed: true,
        worker: 'a',
        judge: 'b',
      );
      expect(
        g.toModelField(),
        '{"mode":"judge_loop","worker":"a","judge":"b"}',
      );
    });
  });

  group('RoutingGroup JSON round-trip', () {
    test('toJson/tryFromJson round-trips a fixed brute-force group', () {
      final g = RoutingGroup(
        mode: RoutingMode.bruteForce,
        isFixed: true,
        models: const ['a', 'b'],
      );
      expect(RoutingGroup.tryFromJson(g.toJson()), g);
    });

    test('tryFromJson returns null on malformed input, never throws', () {
      expect(RoutingGroup.tryFromJson(const {'mode': 'nonsense'}), isNull);
      expect(RoutingGroup.tryFromJson(const {}), isNull);
    });
  });

  group('parseSuggestion', () {
    test('parses a clean brute-force suggestion', () {
      final result = parseSuggestion(
        '{"models":["qwen2.5-72b","llama-3.1-70b","mixtral-8x7b"]}',
        RoutingMode.bruteForce,
      );
      expect(result, isA<SuggestionParsed>());
      final group = (result as SuggestionParsed).group;
      expect(group.models, ['qwen2.5-72b', 'llama-3.1-70b', 'mixtral-8x7b']);
      expect(group.mode, RoutingMode.bruteForce);
    });

    test('parses a suggestion wrapped in prose and a code fence', () {
      final result = parseSuggestion(
        'Sure, here you go:\n```json\n{"worker":"a","judge":"b"}\n```',
        RoutingMode.judgeLoop,
      );
      expect(result, isA<SuggestionParsed>());
      final group = (result as SuggestionParsed).group;
      expect(group.worker, 'a');
      expect(group.judge, 'b');
    });

    test('reports a clear failure reason on unparseable text', () {
      final result = parseSuggestion(
        'I cannot help with that.',
        RoutingMode.bruteForce,
      );
      expect(result, isA<SuggestionParseFailed>());
    });

    test(
      'reports failure when brute force suggestion has fewer than 2 models',
      () {
        final result = parseSuggestion(
          '{"models":["a"]}',
          RoutingMode.bruteForce,
        );
        expect(result, isA<SuggestionParseFailed>());
      },
    );
  });
}
