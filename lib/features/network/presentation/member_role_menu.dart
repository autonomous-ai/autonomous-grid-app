import 'package:flutter/material.dart';

import '../../../infrastructure/api/models/managed_network_member.dart';
import 'access_menu.dart';

/// What one person on the grid may do, at the trailing edge of their row —
/// and, for the owner, the way to change it or take it away.
///
/// Google Docs prints the role on every row and hangs the destructive action
/// off the bottom of that same menu, under a divider. Grid follows the shape
/// exactly, including the part that was thought to be missing: **changing
/// someone's role works**.
///
/// There is no `PATCH …/members/{email}`, and the app read that as "no way to
/// change a role". It isn't: `POST …/members` is an **upsert** — the store
/// writes `ON CONFLICT(network_id, email) DO UPDATE SET roles_json = …` and
/// bumps `member_epoch`, and the CLI's own client documents the call as "add
/// (or update) a member". So a role change is one POST with the new role, on
/// the endpoint the invite already uses.
///
/// **Not DELETE + POST**, which is what the old note told people to do by hand:
/// a POST that fails after the DELETE succeeded drops the person off the grid
/// entirely. The upsert never leaves that gap.
class MemberRoleMenu extends StatelessWidget {
  const MemberRoleMenu({
    super.key,
    required this.role,
    required this.roles,
    required this.onRoleChanged,
    required this.onRemove,
  });

  /// The grant this person holds, or null for one the app doesn't name (a
  /// grid old enough to carry the retired `provider` row).
  final ManagedMemberRole? role;

  /// The roles the viewer may hand out — `invitableRolesFor`, the same list the
  /// invite picker offers. Nobody may raise someone else above their own grant;
  /// the control plane refuses it with 403 `role_above_caller`.
  final List<ManagedMemberRole> roles;

  /// Hands this person the new grant. Both actions are required: the row draws
  /// this menu only for a member the viewer can act on, and a trigger whose
  /// menu does nothing is the thing the whole column was cut for.
  final ValueChanged<ManagedMemberRole> onRoleChanged;

  final VoidCallback onRemove;

  static const double _width = 274;

  @override
  Widget build(BuildContext context) {
    return AccessMenuButton(
      label: role?.label ?? 'Member',
      alignEnd: true,
      tooltip: 'Access options',
      menuSize: accessMenuSize(
        width: _width,
        rows: 1,
        detailRows: roles.length,
        divider: true,
      ),
      itemsBuilder: (menu) => [
        for (final option in roles)
          AccessMenuRow(
            label: option.label,
            detail: option.detail,
            selected: option == role,
            onTap: () {
              menu.close();
              // Picking the role they already hold is not a change — sending it
              // would bump their member epoch and make them refresh a token for
              // nothing.
              if (option != role) onRoleChanged(option);
            },
          ),
        const AccessMenuDivider(),
        AccessMenuRow(
          label: 'Remove access',
          danger: true,
          onTap: () {
            menu.close();
            onRemove();
          },
        ),
      ],
    );
  }
}
