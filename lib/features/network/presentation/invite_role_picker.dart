import 'package:flutter/material.dart';

import '../../../infrastructure/api/models/managed_network_member.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_select_field.dart';

/// What the person being invited will be able to do, beside the address field.
///
/// [AppSelectField] rather than a control built here, for the reason the whole
/// app has one: two places asking the same question must share the widget, or
/// they grow two sets of words. This is the same instrument the access-rule
/// picker uses one section below — one dialog, one kind of "pick one".
///
/// [roles] is passed in, never read from `ManagedMemberRole.values`: a member
/// may only hand out a role they hold themselves, and that rule belongs to
/// `invitableRolesFor`, not to a widget.
///
/// With one role it renders as a field showing that role rather than vanishing.
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

  @override
  Widget build(BuildContext context) {
    final interactive = enabled && roles.length > 1;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: IgnorePointer(
        ignoring: !interactive,
        child: AppSelectField<ManagedMemberRole>(
          label: '',
          showLabel: false,
          value: value,
          // No detail in EITHER place. The menu opens at the field's width
          // (AppSelectField's LayoutBuilder), and this field sits beside an
          // email box — so a sentence ellipsizes in the menu just as it does in
          // the closed field: "Use the models, a…". The caller prints it whole
          // under the row, at dialog width, where it fits.
          showDetailInField: false,
          fill: AppCard.inset,
          options: [
            for (final role in roles)
              AppSelectOption(value: role, label: role.label),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}
