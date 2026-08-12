import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/provider_node/logic/local_throughput.dart';
import 'package:grid_app/features/provider_node/logic/provider_run_controller.dart';
import 'package:grid_app/features/provider_node/logic/throughput_probe.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

NetworkCredential _credential() => const NetworkCredential(
  networkId: 'net',
  name: 'Test grid',
  networkType: 'permissioned',
  lanSignalingUrl: 'https://grid.example/g1',
  accessToken: 'tok',
  refreshToken: '',
  email: '',
  nodeId: '',
  deviceId: '',
  roles: [],
  scopes: [],
  memberEpoch: 1,
  networkEpoch: 1,
  expiresAt: 0,
);

/// A [SelectedNetwork] pinned to the test grid, so the target builder resolves a
/// relay base without wiring the credentials store.
class _FixedNetwork extends SelectedNetwork {
  @override
  NetworkCredential? build() => _credential();
}

class _FakeProbe implements ThroughputProbe {
  _FakeProbe(this.value);
  final double? value;
  int calls = 0;
  String? lastEndpoint;
  String? lastApiKey;
  String? lastModel;

  @override
  Future<double?> measure({
    required String endpoint,
    required String apiKey,
    required String model,
  }) {
    calls++;
    lastEndpoint = endpoint;
    lastApiKey = apiKey;
    lastModel = model;
    return Future.value(value);
  }
}

void main() {
  group('reading tok/s out of a warm-up reply', () {
    test("takes the server's own measured decode rate", () {
      // llama.cpp reports the rate it actually generated at, prompt eval
      // excluded — better than anything timed from the app.
      final rate = parseTokensPerSecond({
        'timings': {'predicted_per_second': 249.5, 'predicted_n': 48},
        'usage': {'completion_tokens': 48},
      });
      expect(rate, 249.5);
    });

    test(
      'computes it from predicted_n / predicted_ms when the rate is absent',
      () {
        final rate = parseTokensPerSecond({
          'timings': {'predicted_n': 20, 'predicted_ms': 100.0},
        });
        expect(rate, closeTo(200, 0.001));
      },
    );

    test('a reply nobody timed reads as blank, not as a round trip divided by '
        'tokens', () {
      // The warm-up goes through the relay, so a wall clock counts the
      // handshake, the hop and the prompt eval: a 250 tok/s machine that
      // answers 48 tokens in 1.4s would be published as 34, beside rates the
      // relay measured properly. Nobody measured this one, and that is what
      // the card has to say.
      expect(
        parseTokensPerSecond({
          'usage': {'completion_tokens': 48},
        }),
        isNull,
      );
    });

    test('a body with nothing timeable reads as null, never zero', () {
      expect(parseTokensPerSecond({}), isNull);
      expect(
        parseTokensPerSecond({
          'timings': {'predicted_n': 0, 'predicted_ms': 0},
        }),
        isNull,
      );
    });
  });

  group('the grid warm-up', () {
    ProviderContainer container({
      ({String endpoint, String apiKey, String model})? target,
      required _FakeProbe probe,
    }) {
      final c = ProviderContainer(
        overrides: [
          throughputWarmupTargetProvider.overrideWithValue(target),
          throughputProbeProvider.overrideWithValue(probe),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test(
      'sends the warm-up to the grid URL with its key, and keeps the number',
      () async {
        final probe = _FakeProbe(180);
        final c = container(
          target: (
            endpoint: 'https://grid.example/g1/relay/v1/chat/completions',
            apiKey: 'tok',
            model: 'qwen3.6-35b-a3b',
          ),
          probe: probe,
        );

        // Nothing to show until the warm-up answers.
        expect(c.read(localThroughputProvider).value, isNull);
        await Future<void>.delayed(Duration.zero);

        expect(c.read(localThroughputProvider).value, 180);
        expect(probe.calls, 1);
        // The grid times it, not localhost: the request carries the grid URL and
        // its bearer token, so the relay can route it to the serving machine.
        expect(
          probe.lastEndpoint,
          'https://grid.example/g1/relay/v1/chat/completions',
        );
        expect(probe.lastApiKey, 'tok');
        expect(probe.lastModel, 'qwen3.6-35b-a3b');
      },
    );

    test('nothing serving means no measurement and no number', () async {
      final probe = _FakeProbe(180);
      final c = container(target: null, probe: probe);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(localThroughputProvider).value, isNull);
      expect(probe.calls, 0);
    });

    test(
      'a machine nobody could time keeps the blank, and asks once',
      () async {
        // The relay may not forward llama.cpp's timings, and an unmeasured
        // machine has to read as unmeasured rather than as a made-up rate.
        final probe = _FakeProbe(null);
        final c = container(
          target: (
            endpoint: 'https://grid.example/g1/relay/v1/chat/completions',
            apiKey: 'tok',
            model: 'qwen3.6-35b-a3b',
          ),
          probe: probe,
        );

        await Future<void>.delayed(Duration.zero);
        expect(c.read(localThroughputProvider).value, isNull);
        // Reading it again must not re-probe: a warm-up is a real generation on
        // the machine the user is about to chat with.
        expect(c.read(localThroughputProvider).value, isNull);
        expect(probe.calls, 1);
      },
    );
  });

  group('the grid warm-up target', () {
    ({String endpoint, String apiKey, String model})? targetFor(
      String? serving,
    ) {
      final c = ProviderContainer(
        overrides: [
          selectedNetworkProvider.overrideWith(_FixedNetwork.new),
          servingModelProvider.overrideWithValue(serving),
        ],
      );
      addTearDown(c.dispose);
      return c.read(throughputWarmupTargetProvider);
    }

    test('points at the grid relay, carries its key, asks the first model', () {
      final target = targetFor('first-model, second-model')!;
      // The grid's own chat endpoint, so the relay times the answer.
      expect(
        target.endpoint,
        'https://grid.example/g1/relay/v1/chat/completions',
      );
      expect(target.apiKey, 'tok');
      // The union joins several with commas; a single engine serves one.
      expect(target.model, 'first-model');
    });

    test('asks for the name the grid advertises, not the gguf on disk', () {
      // A local engine's entry is the filename; the grid knows it by its
      // `--advertise-as` name. Sending the filename asks the relay for a model
      // it has never heard of, and the card then waits forever on a warm-up
      // that could never have answered.
      final target = targetFor('Qwen3.6-35B-A3B-UD-IQ3_S.gguf')!;
      expect(target.model, 'Qwen3.6-35B-A3B');
    });

    test('is null when this machine is serving nothing', () {
      expect(targetFor(null), isNull);
      expect(targetFor(''), isNull);
    });
  });
}
