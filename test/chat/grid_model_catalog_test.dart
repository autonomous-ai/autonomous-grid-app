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

GridOverview _overviewWith(String modelId) => GridOverview(
  stats: const GridStats(models: 1, nodes: 1),
  models: [OverviewModel(id: modelId, modality: 'text')],
  nodes: const [],
);

void main() {
  final foo = _network('grid-foo', 'Foo');

  group('gridModelGroupFrom', () {
    test('a ready overview maps to a ready group with its options', () {
      final group = gridModelGroupFrom(
        foo,
        AsyncData(_overviewWith('maker/m1')),
      );
      expect(group.grid.networkId, 'grid-foo');
      expect(group.status, GridModelStatus.ready);
      expect(group.options.single.id, 'maker/m1');
    });

    test('an errored overview maps to offline with no options', () {
      final group = gridModelGroupFrom(
        foo,
        AsyncError(const GridOverviewUnavailable('down'), StackTrace.empty),
      );
      expect(group.status, GridModelStatus.offline);
      expect(group.options, isEmpty);
    });

    test('a loading overview maps to loading', () {
      final group = gridModelGroupFrom(foo, const AsyncLoading());
      expect(group.status, GridModelStatus.loading);
      expect(group.options, isEmpty);
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
