import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

NetworkCredential _net(
  String id, {
  String? name,
  String networkType = 'permissioned',
  List<String> roles = const ['consumer'],
}) => NetworkCredential(
  networkId: id,
  name: name ?? id,
  networkType: networkType,
  lanSignalingUrl: 'http://127.0.0.1:8090',
  accessToken: 't',
  refreshToken: '',
  email: '',
  nodeId: 'n',
  deviceId: 'd',
  roles: roles,
  scopes: const [],
  memberEpoch: 1,
  networkEpoch: 1,
  expiresAt: 0,
);

CredentialsFile _creds(
  List<NetworkCredential> networks, {
  String? activeNetwork,
  String email = 'dev@autonomous.ai',
}) => CredentialsFile(
  networks: networks,
  activeNetwork: activeNetwork,
  user: {'email': email},
);

void main() {
  group('CredentialsFile.domainGrid', () {
    test('matches a -domain grid named for the login email domain', () {
      final org = _net(
        'g1',
        name: 'autonomous.ai',
        networkType: 'private-domain',
      );
      final other = _net('g2', name: 'other');
      expect(_creds([other, org]).domainGrid?.networkId, 'g1');
    });

    test('ignores a same-named grid that is not a domain grid — the name alone '
        'is a coincidence, not the org grid', () {
      final lookalike = _net('g1', name: 'autonomous.ai'); // permissioned
      expect(_creds([lookalike]).domainGrid, isNull);
    });

    test('null when the email has no domain match among the grids', () {
      final org = _net(
        'g1',
        name: 'autonomous.ai',
        networkType: 'private-domain',
      );
      expect(_creds([org], email: 'dev@example.com').domainGrid, isNull);
    });
  });

  group('CredentialsFile.active — owner-first default', () {
    test(
      'a legacy active_network still wins over the owner/domain preference',
      () {
        final consumer = _net('c', roles: const ['consumer']);
        final owned = _net('o', roles: const ['admin']);
        expect(
          _creds([consumer, owned], activeNetwork: 'c').active?.networkId,
          'c',
        );
      },
    );

    test('prefers a grid the user owns over a consumer grid listed first — a '
        'fresh session lands somewhere the user can actually run a model', () {
      final consumerFirst = _net('test', roles: const ['consumer']);
      final owned = _net('org', roles: const ['admin']);
      expect(_creds([consumerFirst, owned]).active?.networkId, 'org');
    });

    test('among owned grids, prefers the one matching the login domain', () {
      final ownedOther = _net('other', roles: const ['admin']);
      final ownedDomain = _net(
        'org',
        name: 'autonomous.ai',
        networkType: 'private-domain',
        roles: const ['admin'],
      );
      expect(_creds([ownedOther, ownedDomain]).active?.networkId, 'org');
    });

    test('falls back to the login-domain grid when the user owns none', () {
      final consumer = _net('test', roles: const ['consumer']);
      final domain = _net(
        'org',
        name: 'autonomous.ai',
        networkType: 'private-domain',
        roles: const ['consumer'],
      );
      expect(_creds([consumer, domain]).active?.networkId, 'org');
    });

    test('falls back to the first grid with no owner and no domain match', () {
      final a = _net('a', roles: const ['consumer']);
      final b = _net('b', roles: const ['consumer']);
      expect(_creds([a, b], email: 'dev@example.com').active?.networkId, 'a');
    });
  });
}
