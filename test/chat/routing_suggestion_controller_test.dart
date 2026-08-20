import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/chat/logic/routing_group.dart';
import 'package:grid_app/features/chat/logic/routing_suggestion_controller.dart';
import 'package:grid_app/features/network/logic/network_models_provider.dart';
import 'package:grid_app/infrastructure/api/chat_transport.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

NetworkCredential _grid() => const NetworkCredential(
  networkId: 'grid-1',
  name: 'Test grid',
  networkType: 'permissioned',
  lanSignalingUrl: 'http://127.0.0.1:8090',
  accessToken: 'tok',
  refreshToken: '',
  email: 'dev@x.com',
  nodeId: 'node-1',
  deviceId: 'dev',
  roles: ['consumer'],
  scopes: ['consumer:chat'],
  memberEpoch: 1,
  networkEpoch: 1,
  expiresAt: 0,
);

/// Pins [selectedNetworkProvider] to a fixed grid without the session/prefs/
/// store wiring the real notifier reads from disk — mirrors
/// `grid_model_catalog_test.dart`'s `_FixedSelectedNetwork`.
class _FixedSelectedNetwork extends SelectedNetwork {
  _FixedSelectedNetwork(this._fixed);
  final NetworkCredential? _fixed;
  @override
  NetworkCredential? build() => _fixed;
}

/// A one-off completion transport that answers every request with a canned
/// [reply] — the controller's job under test is sending *a* probe and parsing
/// *the* answer, not the exact prompt it sent.
class _FakeChatTransport implements ChatTransport {
  _FakeChatTransport(this.reply);
  final String reply;

  @override
  Stream<ChatStreamEvent> stream({
    required String endpoint,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
  }) async* {
    yield ChatDelta(reply);
    yield const ChatDone();
  }
}

void main() {
  ProviderContainer buildContainer(String reply) => ProviderContainer(
    overrides: [
      selectedNetworkProvider.overrideWith(
        () => _FixedSelectedNetwork(_grid()),
      ),
      networkModelsForProvider(
        'grid-1',
      ).overrideWith((ref) async => ['maker/a', 'maker/b', 'maker/c']),
      chatTransportProvider.overrideWithValue(_FakeChatTransport(reply)),
    ],
  );

  test(
    'starts Loading before fetchSuggestion is ever called — nothing has been '
    'asked yet',
    () {
      final container = buildContainer('{}');
      addTearDown(container.dispose);

      expect(
        container.read(routingSuggestionControllerProvider),
        isA<RoutingSuggestionLoading>(),
      );
    },
  );

  test(
    'a clean JSON answer moves Loading -> Ready with the parsed group, using '
    'parseSuggestion under the hood rather than its own parsing',
    () async {
      final container = buildContainer('{"models":["maker/a","maker/b"]}');
      addTearDown(container.dispose);

      await container
          .read(routingSuggestionControllerProvider.notifier)
          .fetchSuggestion(RoutingMode.bruteForce);

      final state = container.read(routingSuggestionControllerProvider);
      expect(state, isA<RoutingSuggestionReady>());
      final group = (state as RoutingSuggestionReady).group;
      expect(group.mode, RoutingMode.bruteForce);
      expect(group.isFixed, true);
      expect(group.models, ['maker/a', 'maker/b']);
    },
  );

  test(
    'garbage text moves Loading -> Failed with a human-readable reason, never '
    'a fabricated default group',
    () async {
      final container = buildContainer('not json at all');
      addTearDown(container.dispose);

      await container
          .read(routingSuggestionControllerProvider.notifier)
          .fetchSuggestion(RoutingMode.bruteForce);

      final state = container.read(routingSuggestionControllerProvider);
      expect(state, isA<RoutingSuggestionFailed>());
      expect((state as RoutingSuggestionFailed).reason, isNotEmpty);
    },
  );

  test(
    'a clean worker/judge answer parses into a judge-loop group for that mode',
    () async {
      final container = buildContainer(
        '{"worker":"maker/a","judge":"maker/b"}',
      );
      addTearDown(container.dispose);

      await container
          .read(routingSuggestionControllerProvider.notifier)
          .fetchSuggestion(RoutingMode.judgeLoop);

      final state = container.read(routingSuggestionControllerProvider);
      expect(state, isA<RoutingSuggestionReady>());
      final group = (state as RoutingSuggestionReady).group;
      expect(group.mode, RoutingMode.judgeLoop);
      expect(group.worker, 'maker/a');
      expect(group.judge, 'maker/b');
    },
  );

  test('no grid selected fails without ever sending the probe', () async {
    final container = ProviderContainer(
      overrides: [
        selectedNetworkProvider.overrideWith(() => _FixedSelectedNetwork(null)),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(routingSuggestionControllerProvider.notifier)
        .fetchSuggestion(RoutingMode.bruteForce);

    final state = container.read(routingSuggestionControllerProvider);
    expect(state, isA<RoutingSuggestionFailed>());
  });
}
