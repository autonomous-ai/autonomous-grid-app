import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/chat/logic/grid_model_catalog.dart';
import 'package:grid_app/features/network/logic/grid_overview_provider.dart';
import 'package:grid_app/features/network/logic/network_models_provider.dart';
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
        const ['comfyui:i2v'],
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

  group('mediaCapabilitiesOf', () {
    test('flattens a ready overview\'s node capabilities', () {
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
      expect(mediaCapabilitiesOf(overview), ['comfyui:i2v', 'maker/m1']);
    });

    test('is empty while the overview is loading or offline', () {
      expect(mediaCapabilitiesOf(const AsyncLoading()), isEmpty);
      expect(
        mediaCapabilitiesOf(
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
