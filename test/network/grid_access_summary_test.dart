import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/grid_access_summary.dart';
import 'package:grid_app/infrastructure/api/models/managed_network.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

/// The tag on a row in the choose-a-grid list is the only thing telling someone
/// whether the grid they are about to enter is one strangers can read. It is
/// derived, not stored, so the derivation is the guard: labelling an open grid
/// "Invited" would let a user pick it believing the opposite, and nothing later
/// in the app would correct them.

NetworkCredential _grid({
  required String networkType,
  List<String> roles = const ['consumer'],
}) => NetworkCredential(
  networkId: 'net-1',
  name: 'Lab',
  networkType: networkType,
  lanSignalingUrl: 'http://127.0.0.1:8090',
  accessToken: 'tok',
  refreshToken: '',
  email: 'dev@x.com',
  nodeId: 'node-1',
  deviceId: 'dev',
  roles: roles,
  scopes: const ['consumer:chat'],
  memberEpoch: 1,
  networkEpoch: 1,
  expiresAt: 0,
);

void main() {
  group('accessTypeFromWire', () {
    test('places every rule the app can actually create', () {
      for (final type in ManagedNetworkType.values) {
        expect(
          accessTypeFromWire(type.wire),
          type,
          reason: 'the picker offers ${type.label}, so the app must place it',
        );
      }
    });

    test('reads a wire value whatever case the file carries it in', () {
      expect(
        accessTypeFromWire('  PERMISSIONLESS  '),
        ManagedNetworkType.anyone,
      );
    });

    test('admits it cannot place a type this app never offers', () {
      expect(
        accessTypeFromWire('permissioned-providers'),
        isNull,
        reason:
            'retired and web-only, but still live in credentials.toml — '
            'naming the nearest rule would print a rule that is not in force',
      );
    });
  });

  group('gridAccessTagFor', () {
    test('an open grid reads Public whoever the viewer is', () {
      expect(
        gridAccessTagFor(_grid(networkType: 'permissionless')).label,
        'Public',
      );
      expect(
        gridAccessTagFor(
          _grid(networkType: 'permissionless', roles: const ['admin']),
        ).label,
        'Public',
        reason:
            'owning it does not make it private, and which fact the row shows '
            'must not depend on the reader — the old badge showed Owner here '
            'and hid that anyone signed in to Grid could read the grid',
      );
    });

    test('a retired open type still reads Public, not Invited', () {
      // The real case, not a hypothetical: `grid ls` returns exactly this for a
      // live account, and ManagedNetworkType has no member for it.
      expect(
        gridAccessTagFor(_grid(networkType: 'permissioned-providers')).label,
        'Public',
        reason:
            'it is in kPublicNetworkTypes, so the rest of the app treats it as '
            'open — this tag must not be the one place that calls it private',
      );
    });

    test('a private grid you made says Owner, never Invited', () {
      expect(
        gridAccessTagFor(
          _grid(networkType: 'permissioned-public', roles: const ['admin']),
        ).label,
        'Owner',
        reason: 'nobody invited you to the grid you created',
      );
    });

    test('a private grid you were let into says Invited', () {
      expect(
        gridAccessTagFor(_grid(networkType: 'permissioned-public')).label,
        'Invited',
      );
      expect(
        gridAccessTagFor(_grid(networkType: 'domain-restricted')).label,
        'Invited',
      );
    });

    test(
      'every grid gets a tag, so no row is silent about who can read it',
      () {
        for (final wire in [
          '',
          '   ',
          'permissionless',
          'nonsense-from-later',
        ]) {
          expect(gridAccessTagFor(_grid(networkType: wire)).label, isNotEmpty);
        }
      },
    );

    test('an unknown closed type is never mistaken for open', () {
      expect(
        gridAccessTagFor(_grid(networkType: 'some-future-permissioned-kind')),
        isNot(GridAccessTag.public),
        reason:
            'a type this build has never heard of must not be announced as '
            'public — that is the direction that costs the user privacy',
      );
    });
  });
}
