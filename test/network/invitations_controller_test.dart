import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/network/logic/invitations_controller.dart';
import 'package:grid_app/infrastructure/api/models/grid_invitation.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';

GridInvitation _invite(String id) => GridInvitation(
  networkId: id,
  name: id,
  networkType: 'permissioned-public',
  ownerEmail: 'owner@example.com',
  addedBy: 'owner@example.com',
  addedAt: 1700000000,
  roles: const ['both'],
  seen: false,
);

/// A signed-in session, so the controller has a token to poll with. Without one
/// it deliberately does nothing at all — see the last test.
const _signedIn = CredentialsFile(
  networks: [],
  sessionToken: 'sess-1',
  apiUrl: 'https://api.example.com',
);

ProviderContainer _container({
  required ListInvitationsFn list,
  MarkInvitationsSeenFn? mark,
  CredentialsFile? session,
}) {
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWithValue(session ?? _signedIn),
      listInvitationsFnProvider.overrideWithValue(list),
      if (mark != null) markInvitationsSeenFnProvider.overrideWithValue(mark),
      // Never wait on a real minute. Every test here drives `refresh` by hand;
      // this only stops the timer firing underneath them.
      invitationsPollIntervalProvider.overrideWithValue(
        const Duration(days: 1),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

ListInvitationsFn _returns(List<GridInvitation> items, {List<int>? calls}) {
  var n = 0;
  return ({required apiUrl, required sessionToken}) async {
    calls?.add(++n);
    return (items, null);
  };
}

ListInvitationsFn _fails(String message) =>
    ({required apiUrl, required sessionToken}) async => (null, message);

void main() {
  test('a loaded list is what the badge counts', () async {
    final container = _container(
      list: _returns([_invite('grid-a'), _invite('grid-b')]),
    );

    await container.read(invitationsControllerProvider.notifier).refresh();

    final state = container.read(invitationsControllerProvider);
    expect(state, isA<InvitationsReady>());
    expect(state.unseenCount, 2);
  });

  test(
    'a failed FIRST load counts zero rather than a number to guess at',
    () async {
      final container = _container(list: _fails('boom'));

      await container.read(invitationsControllerProvider.notifier).refresh();

      final state = container.read(invitationsControllerProvider);
      expect(state, isA<InvitationsFailed>());
      expect(state.unseenCount, 0);
    },
  );

  test('a failed REFRESH keeps the list it already had', () async {
    // The bug this pins: on a flaky connection the badge would flicker between
    // a number and nothing every minute, which reads as invitations appearing
    // and vanishing rather than as a poll that missed.
    var fail = false;
    final container = _container(
      list: ({required apiUrl, required sessionToken}) async =>
          fail ? (null, 'offline') : ([_invite('grid-a')], null),
    );
    final controller = container.read(invitationsControllerProvider.notifier);
    await controller.refresh();

    fail = true;
    await controller.refresh();

    final state = container.read(invitationsControllerProvider);
    expect(state, isA<InvitationsReady>());
    expect(state.unseenCount, 1);
    expect((state as InvitationsReady).staleError, 'offline');
  });

  test('marking one read drops it without waiting for the next poll', () async {
    // Refetching instead would leave the row on screen for up to a minute,
    // which reads as the tap not having registered.
    final sent = <List<String>>[];
    final container = _container(
      list: _returns([_invite('grid-a'), _invite('grid-b')]),
      mark:
          ({
            required apiUrl,
            required sessionToken,
            required networkIds,
          }) async {
            sent.add(networkIds);
            return (networkIds.length, null);
          },
    );
    final controller = container.read(invitationsControllerProvider.notifier);
    await controller.refresh();

    final error = await controller.markSeen(['grid-a']);

    expect(error, isNull);
    expect(sent, [
      ['grid-a'],
    ]);
    final state = container.read(invitationsControllerProvider);
    expect((state as InvitationsReady).items.single.networkId, 'grid-b');
  });

  test(
    'mark-all sends the ids on screen, not a "dismiss everything"',
    () async {
      // The server has no "all" flag on purpose. Sending ids is what stops an
      // invitation that arrived since the last poll being dismissed by somebody
      // who never saw it.
      final sent = <List<String>>[];
      final container = _container(
        list: _returns([_invite('grid-a'), _invite('grid-b')]),
        mark:
            ({
              required apiUrl,
              required sessionToken,
              required networkIds,
            }) async {
              sent.add(networkIds);
              return (networkIds.length, null);
            },
      );
      final controller = container.read(invitationsControllerProvider.notifier);
      await controller.refresh();

      await controller.markAllSeen();

      expect(sent, [
        ['grid-a', 'grid-b'],
      ]);
      expect(container.read(invitationsControllerProvider).unseenCount, 0);
    },
  );

  test('a failed mark leaves the row where it was', () async {
    final container = _container(
      list: _returns([_invite('grid-a')]),
      mark:
          ({
            required apiUrl,
            required sessionToken,
            required networkIds,
          }) async => (null, 'offline'),
    );
    final controller = container.read(invitationsControllerProvider.notifier);
    await controller.refresh();

    final error = await controller.markSeen(['grid-a']);

    expect(error, 'offline');
    expect(container.read(invitationsControllerProvider).unseenCount, 1);
  });

  test('overlapping refreshes are dropped rather than stacked', () async {
    // A slow answer plus a 60s tick would otherwise queue requests, and the
    // later reply can land first — overwriting a newer list with an older one.
    final calls = <int>[];
    final container = _container(
      list: _returns([_invite('grid-a')], calls: calls),
    );
    final controller = container.read(invitationsControllerProvider.notifier);

    await Future.wait([controller.refresh(), controller.refresh()]);

    expect(calls.length, 1);
  });

  test('signed out, it neither polls nor claims a count', () async {
    var called = false;
    final container = _container(
      session: CredentialsFile.empty,
      list: ({required apiUrl, required sessionToken}) async {
        called = true;
        return (<GridInvitation>[], null);
      },
    );

    await container.read(invitationsControllerProvider.notifier).refresh();

    expect(called, isFalse, reason: 'polling a 401 every minute helps nobody');
    expect(container.read(invitationsControllerProvider).unseenCount, 0);
  });
}
