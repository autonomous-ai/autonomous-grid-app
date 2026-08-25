import 'package:flutter/material.dart';

import '../../../infrastructure/api/models/managed_network_member.dart';
import 'access_menu.dart';

/// What the person being invited will be able to do, under the address field.
///
/// The same trigger the rest of the sheet uses ([AccessMenuButton]) rather than
/// a form field: Google Drive shows the role for an invite the same way it
/// shows one for a person already on the document, and one instrument for one
/// question is what stops two sets of words growing.
///
/// [roles] is passed in, never read from `ManagedMemberRole.values`: a member
/// may only hand out a role they hold themselves, and that rule belongs to
/// `invitableRolesFor`, not to a widget.
///
/// With one role it renders as a plain label rather than vanishing.
/// Disappearing would leave the inviter unable to see WHAT they are granting —
/// the fact that it is not a choice does not make it not worth knowing.
class InviteRolePicker extends StatelessWidget {
  const InviteRolePicker({
    super.key,
    required this.value,
    required this.roles,
    required this.enabled,
    required this.onChanged,
  });

  final ManagedMemberRole value;

  /// The roles this inviter may grant, in order. See `invitableRolesFor`.
  final List<ManagedMemberRole> roles;

  final bool enabled;
  final ValueChanged<ManagedMemberRole> onChanged;

  static const double _menuWidth = 274;

  @override
  Widget build(BuildContext context) {
    return AccessMenuButton(
      label: value.label,
      strong: true,
      enabled: enabled && roles.length > 1,
      tooltip: 'What they can do',
      menuSize: accessMenuSize(
        width: _menuWidth,
        rows: 0,
        detailRows: roles.length,
      ),
      itemsBuilder: (menu) => [
        for (final role in roles)
          AccessMenuRow(
            label: role.label,
            detail: role.detail,
            selected: role == value,
            onTap: () {
              menu.close();
              onChanged(role);
            },
          ),
      ],
    );
  }
}
