import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/grid_access_summary.dart';
import 'package:grid_app/features/network/logic/grid_choice_row.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

/// The line under a grid's name is what somebody picks a grid *on*. Every one
/// of its parts has a "we don't know yet" that reads as a fact if it falls
/// through to zero — a grid still being probed would claim nobody is answering,
/// and a reader would pass over the one grid that was working.

NetworkCredential _grid(
  String name, {
  String networkType = 'permissioned-public',
  List<String> roles = const ['consumer'],
}) => NetworkCredential(
  networkId: name,
  name: name,
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
  group('gridRowMeta', () {
    test('an unanswered probe says so, never that the grid is empty', () {
      expect(gridRowMeta(const GridChecking()), 'Checking…');
      expect(
        gridRowMeta(const GridChecking()),
        isNot(contains('Nobody')),
        reason:
            'every grid is unprobed for the first second, and "nobody '
            'answering" there would send a reader past a working grid',
      );
    });

    test('a grid that did not answer is told apart from an idle one', () {
      expect(
        gridRowMeta(const GridUnreachable()),
        "Can't reach this grid right now",
      );
      expect(
        gridRowMeta(const GridReached(running: false, nodes: 0, models: 0)),
        'Nobody answering right now',
        reason: 'a control plane that is down is not a grid with nobody on it',
      );
    });

    test('counts what is answering, and what it can answer with', () {
      expect(
        gridRowMeta(const GridReached(running: true, nodes: 4, models: 6)),
        '4 computers answering · 6 models',
      );
    });

    test('says one of anything in the singular', () {
      expect(
        gridRowMeta(const GridReached(running: true, nodes: 1, models: 1)),
        '1 computer answering · 1 model',
      );
    });

    test('drops the models clause rather than printing a zero', () {
      expect(
        gridRowMeta(const GridReached(running: true, nodes: 2, models: 0)),
        '2 computers answering',
        reason: '"· 0 models" reads as a fault in a grid that is answering',
      );
    });
  });

  group('groupGrids', () {
    test('leads with what is yours, then invited, then open', () {
      final grouped = groupGrids([
        _grid('open', networkType: 'permissionless'),
        _grid('joined'),
        _grid('mine', roles: const ['admin']),
      ]);
      expect(grouped.map((g) => g.tag).toList(), [
        GridAccessTag.owner,
        GridAccessTag.invited,
        GridAccessTag.public,
      ]);
      expect(grouped.map((g) => g.grids.single.name).toList(), [
        'mine',
        'joined',
        'open',
      ]);
    });

    test('draws no heading over an empty group', () {
      final grouped = groupGrids([_grid('joined')]);
      expect(grouped.length, 1);
      expect(grouped.single.tag, GridAccessTag.invited);
    });

    test('loses no grid, whatever the mix', () {
      final all = [
        _grid('a', networkType: 'permissionless'),
        _grid('b'),
        _grid('c', roles: const ['admin']),
        _grid('d', networkType: 'permissionless'),
      ];
      final grouped = groupGrids(all);
      expect(grouped.expand((g) => g.grids).length, all.length);
    });
  });

  group('filterGrids', () {
    test('a blank query is not a filter', () {
      final all = [_grid('Kelvin grid'), _grid('Water Grid')];
      expect(filterGrids(all, '').length, 2);
      expect(filterGrids(all, '   ').length, 2);
    });

    test('matches however the name is cased or padded', () {
      final all = [_grid('Kelvin grid'), _grid('Water Grid')];
      expect(filterGrids(all, '  WATER ').single.name, 'Water Grid');
    });

    test('matches inside the name, not only at the start', () {
      expect(
        filterGrids([_grid('Kelvin grid')], 'vin').single.name,
        'Kelvin grid',
      );
    });
  });

  group('gridCountLabel', () {
    test('names the whole list when nothing is filtered out', () {
      expect(gridCountLabel(shown: 12, total: 12), '12 grids');
      expect(gridCountLabel(shown: 1, total: 1), '1 grid');
    });

    test('says how much of the list is left while filtering', () {
      expect(gridCountLabel(shown: 3, total: 12), '3 of 12');
      expect(gridCountLabel(shown: 0, total: 12), '0 of 12');
    });
  });
}
