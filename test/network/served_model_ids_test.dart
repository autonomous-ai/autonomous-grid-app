import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/network/logic/grid_overview_provider.dart';
import 'package:grid_app/features/network/logic/network_models_provider.dart';
import 'package:grid_app/features/playground/logic/playground_models.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

/// What a grid serves must not blink to "nothing" every time the app asks the
/// question again. Chat treats an empty option list as "no engine is running
/// yet" and swaps the conversation for that screen — so a list that empties
/// itself for the length of a round trip takes the transcript with it, and
/// opening the model picker (which re-reads `/models` on purpose) did exactly
/// that with the picker still listing a dozen models.

NetworkCredential _network(String id) => NetworkCredential(
  networkId: id,
  name: 'Foo',
  networkType: 'permissioned',
  lanSignalingUrl: 'http://127.0.0.1:8090',
  accessToken: 'tok-$id',
  refreshToken: '',
  email: 'dev@x.com',
  nodeId: 'node-$id',
  deviceId: 'dev',
  roles: const ['consumer'],
  scopes: const ['consumer:chat'],
  memberEpoch: 1,
  networkEpoch: 1,
  expiresAt: 0,
);

/// A container wired to one grid whose `/models` answer waits on whatever
/// [gate] hands back at call time.
///
/// A getter rather than the completer itself: a test swaps in a fresh, *open*
/// gate to hold the second read in flight, and a captured completer would still
/// be the first — already completed — which is the whole state under test.
ProviderContainer _container({
  required List<String> served,
  required Completer<void> Function() gate,
}) {
  final grid = _network('grid-foo');
  return ProviderContainer(
    overrides: [
      selectedNetworkProvider.overrideWith(() => _FixedSelectedNetwork(grid)),
      networkModelsForProvider('grid-foo').overrideWith((ref) async {
        await gate().future;
        return served;
      }),
      gridOverviewForProvider('grid-foo').overrideWith(
        (ref) => Future.value(
          const GridOverview(
            stats: GridStats(models: 0, nodes: 0),
            models: [],
            nodes: [],
          ),
        ),
      ),
    ],
  );
}

void main() {
  test(
    'the grid keeps the models it already listed while they are re-read',
    () async {
      var gate = Completer<void>()..complete();
      final container = _container(served: ['maker/m1'], gate: () => gate);
      addTearDown(container.dispose);

      final sub = container.listen(servedModelIdsProvider, (_, _) {});
      addTearDown(sub.close);
      await pumpEventQueue();
      expect(sub.read(), ['maker/m1']);

      // Opening the chat's model picker does exactly this, on every open.
      gate = Completer<void>();
      container.invalidate(networkModelsForProvider('grid-foo'));
      await pumpEventQueue();

      expect(sub.read(), [
        'maker/m1',
      ], reason: 'the list emptied while the answer was in flight');
    },
  );

  test('the chat still has a model to offer mid-refresh', () async {
    var gate = Completer<void>()..complete();
    final container = _container(served: ['maker/m1'], gate: () => gate);
    addTearDown(container.dispose);

    final sub = container.listen(playgroundModelsProvider, (_, _) {});
    addTearDown(sub.close);
    await pumpEventQueue();
    expect(sub.read().single.id, 'maker/m1');

    gate = Completer<void>();
    container.invalidate(networkModelsForProvider('grid-foo'));
    await pumpEventQueue();

    // An empty list here is what flips the chat to "No engine is running yet".
    expect(
      sub.read().map((o) => o.id),
      ['maker/m1'],
      reason: 'the chat would have shown its no-model screen mid-refresh',
    );
  });

  test(
    'empty until the first answer lands, so nothing is claimed early',
    () async {
      final gate = Completer<void>();
      final container = _container(served: ['maker/m1'], gate: () => gate);
      addTearDown(container.dispose);

      final sub = container.listen(servedModelIdsProvider, (_, _) {});
      addTearDown(sub.close);
      await pumpEventQueue();

      expect(sub.read(), isEmpty);

      gate.complete();
      await pumpEventQueue();
      expect(sub.read(), ['maker/m1']);
    },
  );
}

/// A [SelectedNetwork] pinned to a fixed grid, so the models resolve without the
/// session/prefs/store wiring the real notifier reads from disk.
class _FixedSelectedNetwork extends SelectedNetwork {
  _FixedSelectedNetwork(this._fixed);
  final NetworkCredential? _fixed;
  @override
  NetworkCredential? build() => _fixed;
}
