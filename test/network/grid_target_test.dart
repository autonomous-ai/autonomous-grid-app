import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/core/subscription_model.dart';
import 'package:grid_app/features/network/logic/grid_target.dart';
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
  final bar = _network('grid-bar', 'Bar');

  group("the rail's target menu — where the next message goes", () {
    test('the subscription row comes first and the grids follow in the order '
        'the account holds them — it is the one row that waited on no list, so '
        'it must not appear only once one lands', () {
      final targets = gridTargets(
        networks: [foo, bar],
        offerSubscription: true,
      );
      expect(targets.map((t) => t.label), [
        kSubscriptionModelLabel,
        'Foo',
        'Bar',
      ]);
      expect(targets.first.network, isNull);
    });

    test('a shipped build offers grids and nothing else — the subscription row '
        'is developer-only wherever it appears', () {
      final targets = gridTargets(networks: [foo], offerSubscription: false);
      expect(targets.single.network, foo);
      expect(targets.any(isSubscriptionTarget), isFalse);
    });

    test('an account on no grids still gets the row that needs none, so the '
        'menu is never an empty panel', () {
      final targets = gridTargets(networks: const [], offerSubscription: true);
      expect(targets.single.label, kSubscriptionModelLabel);
      expect(isSubscriptionTarget(targets.single), isTrue);
    });

    test('the pill names the grid, and says so in words when there is none — a '
        'control with no label reads as a broken one', () {
      expect(gridTargetPillLabel(foo), 'Foo');
      expect(gridTargetPillLabel(null), 'No grid');
      expect(gridTargetPillLabel(_network('grid-blank', '  ')), 'No grid');
    });
  });
}
