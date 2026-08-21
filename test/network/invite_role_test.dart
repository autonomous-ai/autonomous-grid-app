import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/api/models/managed_network_member.dart';

void main() {
  group('what an inviter may hand out', () {
    test('an owner or a full member may grant either role', () {
      for (final viewer in [
        ['admin'],
        ['admin', 'both'],
        ['both'],
      ]) {
        expect(invitableRolesFor(viewer), ManagedMemberRole.values);
      }
    });

    test('someone who can only USE the grid may not invite a host', () {
      // The wall the control plane enforces as 403 `role_above_caller`: a member
      // who cannot host must not be able to hand out hosting — a capability they
      // never had. Filtered here so it is never offered, rather than refused
      // after the inviter has committed to it.
      final roles = invitableRolesFor(['consumer']);

      expect(roles, [ManagedMemberRole.use]);
      expect(roles, isNot(contains(ManagedMemberRole.both)));
    });

    test(
      'a legacy provider-only member falls to the narrowest, not the widest',
      () {
        // `provider` is retired but rows predating that still exist. It carries no
        // inference scope, so it is not "can use and share" — reading it as such
        // would let a member grant strictly more than they hold.
        expect(invitableRolesFor(['provider']), [ManagedMemberRole.use]);
      },
    );

    test('an unreadable role set grants the least, never the most', () {
      for (final viewer in <List<String>>[
        [],
        ['nonsense'],
      ]) {
        expect(invitableRolesFor(viewer), [ManagedMemberRole.use]);
      }
    });

    test('roles are matched case-insensitively', () {
      expect(invitableRolesFor(['BOTH']), ManagedMemberRole.values);
    });
  });

  group('the wire contract', () {
    test('only the two roles the managed endpoint accepts exist', () {
      // `admin` (no co-admin via an app) and `provider` (retired) are both 400s.
      expect(ManagedMemberRole.values.map((r) => r.wire), ['consumer', 'both']);
    });

    test('the widest grant is the default, as every invite used to send', () {
      expect(ManagedMemberRole.fallback, ManagedMemberRole.both);
    });
  });
}
