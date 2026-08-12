import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/provider_node/logic/local_throughput.dart';
import 'package:grid_app/features/provider_node/logic/provider_run_controller.dart';
import 'package:grid_app/features/provider_node/logic/throughput_probe.dart';

class _FakeProbe implements ThroughputProbe {
  _FakeProbe(this.value);
  final double? value;
  int calls = 0;
  String? lastEndpoint;
  String? lastModel;

  @override
  Future<double?> measure({required String endpoint, required String model}) {
    calls++;
    lastEndpoint = endpoint;
    lastModel = model;
    return Future.value(value);
  }
}

void main() {
  group('reading tok/s out of a warm-up reply', () {
    test("prefers the server's own measured decode rate", () {
      // llama.cpp reports the rate it actually generated at, prompt eval
      // excluded — better than anything timed from the app.
      final rate = parseTokensPerSecond({
        'timings': {'predicted_per_second': 249.5, 'predicted_n': 48},
        'usage': {'completion_tokens': 48},
      }, const Duration(seconds: 5));
      expect(rate, 249.5);
    });

    test(
      'computes it from predicted_n / predicted_ms when the rate is absent',
      () {
        final rate = parseTokensPerSecond({
          'timings': {'predicted_n': 20, 'predicted_ms': 100.0},
        }, const Duration(seconds: 9));
        expect(rate, closeTo(200, 0.001));
      },
    );

    test('falls back to wall-clock over completion tokens', () {
      // Rough — it counts the round trip and the prompt — but a number beats a
      // blank when the point is "fast or slow".
      final rate = parseTokensPerSecond({
        'usage': {'completion_tokens': 30},
      }, const Duration(seconds: 2));
      expect(rate, closeTo(15, 0.001));
    });

    test('a body with nothing timeable reads as null, never zero', () {
      expect(parseTokensPerSecond({}, const Duration(seconds: 1)), isNull);
      expect(
        parseTokensPerSecond({
          'usage': {'completion_tokens': 0},
        }, Duration.zero),
        isNull,
      );
    });
  });

  group('the local warm-up', () {
    ProviderContainer container({
      String? endpoint,
      String? model,
      required _FakeProbe probe,
    }) {
      final c = ProviderContainer(
        overrides: [
          localProviderEndpointProvider.overrideWithValue(endpoint),
          servingModelProvider.overrideWithValue(model),
          throughputProbeProvider.overrideWithValue(probe),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('measures once the engine is up and keeps the number', () async {
      final probe = _FakeProbe(180);
      final c = container(
        endpoint: 'http://localhost:9',
        model: 'qwen3.6-35b-a3b',
        probe: probe,
      );

      // Nothing to show until the warm-up answers.
      expect(c.read(localThroughputProvider), isNull);
      await Future<void>.delayed(Duration.zero);

      expect(c.read(localThroughputProvider), 180);
      expect(probe.calls, 1);
      // The union may join models with commas; the warm-up asks the first.
      expect(probe.lastModel, 'qwen3.6-35b-a3b');
      expect(probe.lastEndpoint, 'http://localhost:9');
    });

    test('asks the first model when several are joined', () async {
      final probe = _FakeProbe(60);
      final c = container(
        endpoint: 'http://localhost:9',
        model: 'first-model, second-model',
        probe: probe,
      );
      // Read to instantiate the lazy provider — that's what the visible card
      // does, and what kicks the warm-up off.
      c.read(localThroughputProvider);
      await Future<void>.delayed(Duration.zero);
      expect(probe.lastModel, 'first-model');
    });

    test('nothing serving means no measurement and no number', () async {
      final probe = _FakeProbe(180);
      final c = container(endpoint: null, model: null, probe: probe);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(localThroughputProvider), isNull);
      expect(probe.calls, 0);
    });
  });
}
