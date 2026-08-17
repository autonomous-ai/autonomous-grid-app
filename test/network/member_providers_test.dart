import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/network/logic/member_providers.dart';
import 'package:grid_app/infrastructure/api/models/managed_network_member.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

const _net = 'net-1';

const _member = ManagedNetworkMember(
  email: 'a@example.com',
  roles: ['consumer'],
  status: 'active',
);

ProviderContainer _container({
  MemberListFn? list,
  MemberAddFn? add,
  MemberRemoveFn? remove,
  String? sessionToken = 'tok',
}) {
  final container = ProviderContainer(
    overrides: [
      if (list != null) memberListFnProvider.overrideWithValue(list),
      if (add != null) memberAddFnProvider.overrideWithValue(add),
      if (remove != null) memberRemoveFnProvider.overrideWithValue(remove),
      sessionProvider.overrideWithValue(
        CredentialsFile(networks: const [], sessionToken: sessionToken),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Reads the members future while holding a subscription, so the autoDispose
/// provider isn't torn down mid-load by a bare one-off `read`.
Future<List<ManagedNetworkMember>> _readMembers(ProviderContainer container) {
  container.listen(networkMembersProvider(_net), (_, _) {});
  return container.read(networkMembersProvider(_net).future);
}

void main() {
  group('networkMembersProvider', () {
    test('returns the members on success', () async {
      final container = _container(
        list:
            ({
              required apiUrl,
              required sessionToken,
              required networkId,
            }) async => ([_member], null),
      );

      final members = await _readMembers(container);

      expect(members.single.email, 'a@example.com');
    });
  });

  group('addMemberActionProvider', () {
    test('returns null and forwards email + roles on success', () async {
      String? sentEmail;
      List<String>? sentRoles;
      final container = _container(
        add:
            ({
              required apiUrl,
              required sessionToken,
              required networkId,
              required email,
              required roles,
            }) async {
              sentEmail = email;
              sentRoles = roles;
              return (_member, null);
            },
      );

      final error = await container.read(addMemberActionProvider)(
        networkId: _net,
        email: 'a@example.com',
        roles: ['provider'],
      );

      expect(error, isNull);
      expect(sentEmail, 'a@example.com');
      expect(sentRoles, ['provider']);
    });

    test('surfaces the API error message', () async {
      final container = _container(
        add:
            ({
              required apiUrl,
              required sessionToken,
              required networkId,
              required email,
              required roles,
            }) async => (null, "You've reached your plan's member limit."),
      );

      final error = await container.read(addMemberActionProvider)(
        networkId: _net,
        email: 'a@example.com',
        roles: ['consumer'],
      );

      expect(error, contains('member limit'));
    });

    test('fails fast when not signed in, without calling the API', () async {
      var called = false;
      final container = _container(
        add:
            ({
              required apiUrl,
              required sessionToken,
              required networkId,
              required email,
              required roles,
            }) async {
              called = true;
              return (_member, null);
            },
        sessionToken: null,
      );

      final error = await container.read(addMemberActionProvider)(
        networkId: _net,
        email: 'a@example.com',
        roles: ['consumer'],
      );

      expect(error, contains('Sign in'));
      expect(called, isFalse);
    });
  });

  group('removeMemberActionProvider', () {
    test('returns null on success', () async {
      final container = _container(
        remove:
            ({
              required apiUrl,
              required sessionToken,
              required networkId,
              required email,
            }) async => (true, null),
      );

      final error = await container.read(removeMemberActionProvider)(
        networkId: _net,
        email: 'a@example.com',
      );

      expect(error, isNull);
    });

    test('surfaces the API error message', () async {
      final container = _container(
        remove:
            ({
              required apiUrl,
              required sessionToken,
              required networkId,
              required email,
            }) async => (false, 'Network owner cannot be removed.'),
      );

      final error = await container.read(removeMemberActionProvider)(
        networkId: _net,
        email: 'owner@example.com',
      );

      expect(error, contains('cannot be removed'));
    });
  });

  group('selectedGridMemberCountProvider', () {
    test('counts everyone the roster returns', () async {
      final container = _countContainer(
        list:
            ({
              required apiUrl,
              required sessionToken,
              required networkId,
            }) async => ([_member, _domainMember], null),
      );
      container.listen(selectedGridMemberCountProvider, (_, _) {});

      await container.read(networkMembersProvider(_net).future);

      expect(container.read(selectedGridMemberCountProvider), 2);
    });

    test('stays null when the roster cannot be read', () async {
      // The pill drops the figure entirely here — a 0 would read as "nobody is
      // on this grid" when the truth is that we never got an answer.
      final container = _countContainer(
        list:
            ({
              required apiUrl,
              required sessionToken,
              required networkId,
            }) async => (null, 'Members are unavailable.'),
      );
      container.listen(selectedGridMemberCountProvider, (_, _) {});

      // Let the failing roster call settle. Not awaited through
      // `networkMembersProvider(...).future`: that future carries the error, and
      // the assertion here is about what the *count* does with it.
      await Future<void>.delayed(Duration.zero);

      expect(container.read(selectedGridMemberCountProvider), isNull);
    });

    test('is null with no grid selected, without asking for a roster', () {
      var asked = false;
      final container = _countContainer(
        grid: null,
        list:
            ({
              required apiUrl,
              required sessionToken,
              required networkId,
            }) async {
              asked = true;
              return ([_member], null);
            },
      );

      expect(container.read(selectedGridMemberCountProvider), isNull);
      expect(asked, isFalse);
    });
  });
}

/// A member with no allowlist row — on the grid because their email is on its
/// domain. Counted like anyone else: they use the grid like anyone else.
const _domainMember = ManagedNetworkMember(
  email: 'b@example.com',
  roles: ['both'],
  status: 'active',
  source: 'domain',
);

/// [_container] plus a selected grid, which is what the count provider reads to
/// know whose roster to ask for.
ProviderContainer _countContainer({
  required MemberListFn list,
  NetworkCredential? grid = _grid,
}) {
  final container = ProviderContainer(
    overrides: [
      memberListFnProvider.overrideWithValue(list),
      selectedNetworkProvider.overrideWith(() => _FixedSelectedNetwork(grid)),
      sessionProvider.overrideWithValue(
        const CredentialsFile(networks: [], sessionToken: 'tok'),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

const _grid = NetworkCredential(
  networkId: _net,
  name: 'example.com',
  networkType: 'private-domain',
  lanSignalingUrl: 'http://127.0.0.1:9000',
  accessToken: 'a',
  refreshToken: 'r',
  email: 'a@example.com',
  nodeId: 'node-1',
  deviceId: 'dev-1',
  roles: ['both'],
  scopes: ['consumer:chat'],
  memberEpoch: 1,
  networkEpoch: 1,
  expiresAt: 0,
);

class _FixedSelectedNetwork extends SelectedNetwork {
  _FixedSelectedNetwork(this._fixed);
  final NetworkCredential? _fixed;
  @override
  NetworkCredential? build() => _fixed;
}
