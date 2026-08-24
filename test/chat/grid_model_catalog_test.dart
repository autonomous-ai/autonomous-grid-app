import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/chat/logic/grid_model_catalog.dart';
import 'package:grid_app/features/chat/logic/routing_group.dart';
import 'package:grid_app/features/network/logic/grid_overview_provider.dart';
import 'package:grid_app/features/network/logic/network_models_provider.dart';
import 'package:grid_app/features/playground/logic/playground_models.dart';
import 'package:grid_app/features/playground/logic/playground_request.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

NetworkCredential _network(String id, String name) => NetworkCredential(
  networkId: id,
  name: name,
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

void main() {
  final foo = _network('grid-foo', 'Foo');

  group('gridModelGroupFrom', () {
    test('a ready /models list maps to a ready group with its options', () {
      final group = gridModelGroupFrom(
        foo,
        const AsyncData(['maker/m1']),
        const [],
      );
      expect(group.grid.networkId, 'grid-foo');
      expect(group.status, GridModelStatus.ready);
      expect(group.options.single.id, 'maker/m1');
    });

    test('the auto routing model from /models is listed like any other — the '
        'whole reason this reads /models instead of the overview', () {
      final group = gridModelGroupFrom(
        foo,
        const AsyncData(['auto', 'maker/m1']),
        const [],
      );
      expect(group.options.map((o) => o.id), ['auto', 'maker/m1']);
    });

    test('node media capabilities add the Image/Video modes on top of the '
        'served models', () {
      final group = gridModelGroupFrom(
        foo,
        const AsyncData(['maker/m1']),
        const [
          OverviewNode(name: 'n1', online: true, models: ['comfyui:i2v']),
        ],
      );
      expect(group.options.map((o) => o.id), contains('maker/m1'));
      expect(group.options.map((o) => o.label), contains('Image → video'));
    });

    test('an errored /models list maps to offline with no options', () {
      final group = gridModelGroupFrom(
        foo,
        AsyncError(const GridOverviewUnavailable('down'), StackTrace.empty),
        const [],
      );
      expect(group.status, GridModelStatus.offline);
      expect(group.options, isEmpty);
    });

    test('a loading /models list maps to loading', () {
      final group = gridModelGroupFrom(foo, const AsyncLoading(), const []);
      expect(group.status, GridModelStatus.loading);
      expect(group.options, isEmpty);
    });
  });

  group('nodesOf', () {
    test('hands over a ready overview\'s nodes', () {
      final overview = AsyncData(
        GridOverview(
          stats: const GridStats(models: 0, nodes: 1),
          models: const [],
          nodes: const [
            OverviewNode(
              name: 'n1',
              online: true,
              models: ['comfyui:i2v', 'maker/m1'],
            ),
          ],
        ),
      );
      expect(nodesOf(overview).single.models, ['comfyui:i2v', 'maker/m1']);
    });

    test('is empty while the overview is loading or offline', () {
      expect(nodesOf(const AsyncLoading()), isEmpty);
      expect(
        nodesOf(
          AsyncError(const GridOverviewUnavailable('x'), StackTrace.empty),
        ),
        isEmpty,
      );
    });
  });

  test('catalog lists only the selected grid, hiding the others', () {
    final container = ProviderContainer(
      overrides: [
        selectedNetworkProvider.overrideWith(() => _FixedSelectedNetwork(foo)),
        // Keep the read offline: stub the selected grid's model/overview probes
        // so no real relay call fires (and none logs to a disposed container).
        networkModelsForProvider(
          'grid-foo',
        ).overrideWith((ref) => Future.value(const <String>[])),
        gridOverviewForProvider('grid-foo').overrideWith(
          (ref) => Future.value(
            GridOverview(
              stats: const GridStats(models: 0, nodes: 0),
              models: const [],
              nodes: const [],
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final catalog = container.read(gridModelCatalogProvider);
    // Only the selected grid — any other grid in the session stays hidden.
    expect(catalog.map((g) => g.grid.networkId), ['grid-foo']);
    // The stubbed probes haven't resolved yet — the group starts loading.
    expect(catalog.single.status, GridModelStatus.loading);
  });

  test('re-reading /models — what opening the picker asks for — swaps the list '
      'for the new one, and shows the old one meanwhile', () async {
    var served = ['maker/m1'];
    var calls = 0;
    // Open once the first read is over, so the refetch can be held mid-flight
    // and the menu inspected while it waits.
    var gate = Completer<void>()..complete();
    final container = ProviderContainer(
      overrides: [
        selectedNetworkProvider.overrideWith(() => _FixedSelectedNetwork(foo)),
        networkModelsForProvider('grid-foo').overrideWith((ref) async {
          calls++;
          await gate.future;
          return served;
        }),
        gridOverviewForProvider('grid-foo').overrideWith(
          (ref) => Future.value(
            GridOverview(
              stats: const GridStats(models: 0, nodes: 0),
              models: const [],
              nodes: const [],
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    // The model pill holds the catalog open for as long as the composer is
    // mounted — which is why nothing re-reads it on its own.
    final sub = container.listen(gridModelCatalogProvider, (_, _) {});
    addTearDown(sub.close);
    await pumpEventQueue();
    expect(calls, 1);
    expect(
      container.read(gridModelCatalogProvider).single.options.single.id,
      'maker/m1',
    );

    served = ['maker/m1', 'maker/m2'];
    gate = Completer<void>();
    container.invalidate(networkModelsForProvider('grid-foo'));
    await pumpEventQueue();

    final inFlight = container.read(gridModelCatalogProvider).single;
    expect(calls, 2);
    expect(inFlight.status, GridModelStatus.ready);
    expect(inFlight.options.map((o) => o.id), ['maker/m1']);

    gate.complete();
    await pumpEventQueue();
    expect(
      container.read(gridModelCatalogProvider).single.options.map((o) => o.id),
      ['maker/m1', 'maker/m2'],
    );
  });

  group('the orchestrator rows offered beside a grid\'s models', () {
    test('a grid with no auto router offers none, so no row can be tapped '
        'into a mode the grid has nothing to run', () {
      expect(
        routingModeOptions(const [
          PlaygroundModelOption(
            id: 'qwen',
            label: 'qwen',
            modality: PlaygroundModality.text,
          ),
        ]),
        isEmpty,
      );
    });

    test('a grid serving auto offers one row per mode, each named the way '
        'the mode is named everywhere else', () {
      // The relay's own `/models` never lists a bare `auto` id (one name per
      // row, so a generic client can tell the modes apart) — it lists this
      // display name instead. See `_kAutoRouterDisplayName`.
      final rows = routingModeOptions(const [
        PlaygroundModelOption(
          id: 'Auto',
          label: 'Auto',
          modality: PlaygroundModality.text,
        ),
        PlaygroundModelOption(
          id: 'maker/a',
          label: 'maker/a',
          modality: PlaygroundModality.text,
        ),
        PlaygroundModelOption(
          id: 'maker/b',
          label: 'maker/b',
          modality: PlaygroundModality.text,
        ),
      ]);

      expect(rows.map((o) => o.id), [
        for (final mode in RoutingMode.values) routingModelId(mode),
      ]);
      expect(rows.map((o) => o.label), ['Brute Force', 'Feedback Loop']);
    });

    test("the rows read images exactly when the router does — they are the "
        "router, so a vision lock must not answer differently for them", () {
      const realModels = [
        PlaygroundModelOption(
          id: 'maker/a',
          label: 'maker/a',
          modality: PlaygroundModality.text,
        ),
        PlaygroundModelOption(
          id: 'maker/b',
          label: 'maker/b',
          modality: PlaygroundModality.text,
        ),
      ];
      const seeing = PlaygroundModelOption(
        id: 'Auto',
        label: 'Auto',
        modality: PlaygroundModality.text,
        vision: true,
      );
      const blind = PlaygroundModelOption(
        id: 'Auto',
        label: 'Auto',
        modality: PlaygroundModality.text,
      );

      expect(
        routingModeOptions([seeing, ...realModels]).every((o) => o.vision),
        isTrue,
      );
      expect(
        routingModeOptions([blind, ...realModels]).any((o) => o.vision),
        isFalse,
      );
    });

    test('a bare-lowercase "auto" row is not the relay\'s router signal — '
        'the relay never sends one, so trusting it would leave the rows '
        'permanently empty on every real grid', () {
      expect(
        routingModeOptions(const [
          PlaygroundModelOption(
            id: 'auto',
            label: 'auto',
            modality: PlaygroundModality.text,
          ),
        ]),
        isEmpty,
      );
    });

    test('a router with zero real models offers no row — the dialog it '
        'would open has nothing to pick and no way to confirm', () {
      expect(
        routingModeOptions(const [
          PlaygroundModelOption(
            id: 'Auto',
            label: 'Auto',
            modality: PlaygroundModality.text,
          ),
        ]),
        isEmpty,
      );
    });

    test('a router with exactly one real model still offers no row — Brute '
        'Force and Feedback Loop both need two to route between', () {
      expect(
        routingModeOptions(const [
          PlaygroundModelOption(
            id: 'Auto',
            label: 'Auto',
            modality: PlaygroundModality.text,
          ),
          PlaygroundModelOption(
            id: 'maker/a',
            label: 'maker/a',
            modality: PlaygroundModality.text,
          ),
        ]),
        isEmpty,
      );
    });
  });

  group('answerableGridOptions', () {
    test('drops the relay\'s own "Brute Force" / "Feedback Loop" catalog '
        'rows — routingModeOptions already offers the same two modes, and a '
        'tap on the relay\'s row skips the Fixed/Dynamic choice entirely', () {
      const models = [
        PlaygroundModelOption(
          id: 'Auto',
          label: 'Auto',
          modality: PlaygroundModality.text,
        ),
        PlaygroundModelOption(
          id: 'Brute Force',
          label: 'Brute Force',
          modality: PlaygroundModality.text,
        ),
        PlaygroundModelOption(
          id: 'Feedback Loop',
          label: 'Feedback Loop',
          modality: PlaygroundModality.text,
        ),
        PlaygroundModelOption(
          id: 'qwen',
          label: 'qwen',
          modality: PlaygroundModality.text,
        ),
      ];

      expect(answerableGridOptions(models).map((o) => o.id), [
        'Auto',
        'qwen',
      ]);
    });

    test('also drops "Auto" once there are zero real models behind it — '
        'a router with nothing to route to is not a model to pick either', () {
      const models = [
        PlaygroundModelOption(
          id: 'Auto',
          label: 'Auto',
          modality: PlaygroundModality.text,
        ),
        PlaygroundModelOption(
          id: 'Brute Force',
          label: 'Brute Force',
          modality: PlaygroundModality.text,
        ),
        PlaygroundModelOption(
          id: 'Feedback Loop',
          label: 'Feedback Loop',
          modality: PlaygroundModality.text,
        ),
      ];

      expect(answerableGridOptions(models), isEmpty);
    });
  });

  test('catalog is empty when no grid is selected', () {
    final container = ProviderContainer(
      overrides: [
        selectedNetworkProvider.overrideWith(() => _FixedSelectedNetwork(null)),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(gridModelCatalogProvider), isEmpty);
  });
}

/// A [SelectedNetwork] pinned to a fixed grid, so the catalog resolves without
/// the session/prefs/store wiring the real notifier reads from disk.
class _FixedSelectedNetwork extends SelectedNetwork {
  _FixedSelectedNetwork(this._fixed);
  final NetworkCredential? _fixed;
  @override
  NetworkCredential? build() => _fixed;
}
