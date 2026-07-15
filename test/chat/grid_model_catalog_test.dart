import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/chat/logic/grid_model_catalog.dart';
import 'package:grid_app/features/network/logic/grid_overview_provider.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';
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

  test('catalog builds one group per grid in the session', () {
    final bar = _network('grid-bar', 'Bar');
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWithValue(
          CredentialsFile(networks: [foo, bar], activeNetwork: 'grid-foo'),
        ),
      ],
    );
    addTearDown(container.dispose);

    final catalog = container.read(gridModelCatalogProvider);
    expect(catalog.map((g) => g.grid.networkId), ['grid-foo', 'grid-bar']);
    // Overviews haven't resolved (no relay in tests) — both start loading.
    expect(catalog.every((g) => g.status == GridModelStatus.loading), isTrue);
  });
}
