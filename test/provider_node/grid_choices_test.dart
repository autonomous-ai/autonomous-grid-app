import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/provider_node/logic/grid_choices.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

NetworkCredential _grid(String id, {bool canShare = false}) =>
    NetworkCredential(
      networkId: id,
      name: id,
      networkType: 'permissioned',
      lanSignalingUrl: 'http://127.0.0.1:8090',
      accessToken: 'tok-$id',
      refreshToken: '',
      email: 'dev@x.com',
      nodeId: 'node-$id',
      deviceId: 'dev',
      roles: const ['consumer'],
      scopes: canShare
          ? const ['consumer:chat', 'provider:poll']
          : const ['consumer:chat'],
      memberEpoch: 1,
      networkEpoch: 1,
      expiresAt: 0,
    );

void main() {
  group('the grids offered beside the one being set up', () {
    test('leaves out the grid the page is already about', () {
      final here = _grid('here', canShare: true);
      final choices = buildGridChoices([here, _grid('there')], here);

      expect(choices.canShare, isEmpty);
      expect(choices.viewOnly.map((g) => g.networkId), ['there']);
    });

    test('a lone grid offers nothing to switch to', () {
      final here = _grid('here', canShare: true);

      expect(buildGridChoices([here], here).isEmpty, isTrue);
    });

    test('splits on whether a model can be shared, not on who owns it', () {
      final here = _grid('here');
      // Someone else's grid that granted this account provider:poll belongs
      // with the ones an engine can actually run on.
      final guest = _grid('guest', canShare: true);
      final choices = buildGridChoices([here, guest, _grid('reader')], here);

      expect(choices.canShare.map((g) => g.networkId), ['guest']);
      expect(choices.viewOnly.map((g) => g.networkId), ['reader']);
      expect(choices.isSplit, isTrue);
    });

    test('one group alone is not a split, so it carries no headings', () {
      final here = _grid('here');
      final choices = buildGridChoices([
        here,
        _grid('a', canShare: true),
        _grid('b', canShare: true),
      ], here);

      expect(choices.isSplit, isFalse);
      expect(choices.viewOnly, isEmpty);
    });

    test('keeps the credentials file order so chips never reshuffle', () {
      final here = _grid('here');
      final grids = [_grid('c'), here, _grid('a'), _grid('b')];

      expect(buildGridChoices(grids, here).viewOnly.map((g) => g.name), [
        'c',
        'a',
        'b',
      ]);
    });
  });
}
