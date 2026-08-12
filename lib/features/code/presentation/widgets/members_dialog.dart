import 'package:flutter/material.dart';

import 'code_dialog.dart';
import 'members_card.dart';

/// Who is in the project, and — for its owner — the way to admit somebody.
///
/// A dialog rather than a card down the page: the project screen is a
/// conversation now, and the member list is looked at when somebody joins or
/// when a branch has to be published for a colleague, not on the way past.
Future<void> showMembersDialog(
  BuildContext context, {
  required String projectId,
  required bool canInvite,
}) => showDialog<void>(
  context: context,
  builder: (context) => CodeDialog(
    title: 'Who is in it',
    confirmLabel: 'Done',
    onConfirm: () => Navigator.of(context).pop(),
    child: MembersCard(projectId: projectId, canInvite: canInvite),
  ),
);
