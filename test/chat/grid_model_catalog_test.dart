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

/// Reads the catalog once the grid overviews have settled out of `loading`,
/// keeping the autoDispose chain alive while they resolve.
Future<List<GridModelGroup>> _settled(ProviderContainer container) async {
  final sub = container.listen(gridModelCatalogProvider, (_, _) {});
  addTearDown(sub.close);
  for (var i = 0; i < 40; i++) {
    final catalog = container.read(gridModelCatalogProvider);
    final done = catalog.every((g) => g.status != GridModelStatus.loading);
    if (done) return catalog;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return container.read(gridModelCatalogProvider);
}

void main() {
  final foo = _network('grid-foo', 'Foo');
  final bar = _network('grid-bar', 'Bar');

  test('groups each grid, marking a reachable one ready and a failing one '
      'offline', () async {
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWithValue(
          CredentialsFile(networks: [foo, bar], activeNetwork: 'grid-foo'),
        ),
        gridOverviewForProvider(
          'grid-foo',
        ).overrideWith((ref) async => _overviewWith('maker/m1')),
        gridOverviewForProvider('grid-bar').overrideWith(
          (ref) => throw const GridOverviewUnavailable('down'),
        ),
      ],
    );
    addTearDown(container.dispose);

    final catalog = await _settled(container);
    expect(catalog, hasLength(2));

    final fooGroup = catalog.firstWhere((g) => g.grid.networkId == 'grid-foo');
    expect(fooGroup.status, GridModelStatus.ready);
    expect(fooGroup.options.single.id, 'maker/m1');

    final barGroup = catalog.firstWhere((g) => g.grid.networkId == 'grid-bar');
    expect(barGroup.status, GridModelStatus.offline);
    expect(barGroup.options, isEmpty);
  });

  test('reports loading before a grid overview resolves', () {
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWithValue(
          CredentialsFile(networks: [foo], activeNetwork: 'grid-foo'),
        ),
        gridOverviewForProvider(
          'grid-foo',
        ).overrideWith((ref) => Future.value(_overviewWith('maker/m1'))),
      ],
    );
    addTearDown(container.dispose);

    final sub = container.listen(gridModelCatalogProvider, (_, _) {});
    addTearDown(sub.close);

    // Read synchronously, before the future completes.
    final group = container.read(gridModelCatalogProvider).single;
    expect(group.status, GridModelStatus.loading);
  });
}
