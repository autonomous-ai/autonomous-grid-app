// test/chat/routing_group_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/routing_group.dart';

void main() {
  group('the id a routing mode wears in the model picker', () {
    test('round-trips, so a chat saved on a mode reopens on that mode rather '
        'than on a name the picker no longer recognises', () {
      for (final mode in RoutingMode.values) {
        expect(routingModeForModelId(routingModelId(mode)), mode);
      }
    });

    test('an ordinary model id names no mode — a plain pick must not be read '
        'as an orchestrator row', () {
      expect(routingModeForModelId('qwen/qwen3.6-27b'), isNull);
      expect(routingModeForModelId('auto'), isNull);
      expect(routingModeForModelId(''), isNull);
    });
  });

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

    test('fixed brute force with a pinned aggregator adds it to the JSON', () {
      final g = RoutingGroup(
        mode: RoutingMode.bruteForce,
        isFixed: true,
        models: const ['a', 'b', 'c'],
        aggregator: 'c',
      );
      expect(
        g.toModelField(),
        '{"mode":"brute_force","models":["a","b","c"],"aggregator":"c"}',
      );
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

    test('toJson/tryFromJson round-trips a pinned aggregator too', () {
      final g = RoutingGroup(
        mode: RoutingMode.bruteForce,
        isFixed: true,
        models: const ['a', 'b'],
        aggregator: 'b',
      );
      expect(RoutingGroup.tryFromJson(g.toJson()), g);
    });

    test('tryFromJson returns null on malformed input, never throws', () {
      expect(RoutingGroup.tryFromJson(const {'mode': 'nonsense'}), isNull);
      expect(RoutingGroup.tryFromJson(const {}), isNull);
    });
  });
}
