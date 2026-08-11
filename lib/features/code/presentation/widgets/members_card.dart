import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/detail_widgets.dart';
import '../../../../shared/widgets/labeled_field.dart';
import '../../../../shared/widgets/toast.dart';
import '../../logic/code_members_controller.dart';
import '../../logic/code_project.dart';
import 'code_dialog.dart';

/// Who is in the project.
///
/// The member key is shown rather than hidden: it is what publishing somebody
/// else's work takes, and it is **different in every grid**, so a key copied
/// from elsewhere aims at a branch that does not exist.
class MembersCard extends ConsumerWidget {
  const MembersCard({
    super.key,
    required this.projectId,
    this.canInvite = true,
  });

  final String projectId;

  /// Only the project's owner may admit people, so the button is offered only
  /// where it would work.
  final bool canInvite;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(codeMembersProvider(projectId));
    return DetailSection(
      title: 'Who is in it',
      trailing: canInvite
          ? TextButton(
              onPressed: () => _invite(context, ref),
              child: const Text('Invite'),
            )
          : null,
      children: switch (members) {
        AsyncData(:final value) => [
          for (final member in value) _MemberRow(member: member),
        ],
        // A row with an empty value reads as a broken row. Both of these
        // states get a sentence in the label and nothing on the right, which is
        // what MetaRow's own layout does with a blank value anyway — so they
        // say so explicitly rather than looking half-rendered.
        AsyncError() => const [
          MetaRow(label: 'Couldn’t read who is in this project', value: '—'),
        ],
        _ => const [MetaRow(label: 'Reading the member list…', value: '—')],
      },
    );
  }

  Future<void> _invite(BuildContext context, WidgetRef ref) async {
    final email = await showDialog<String>(
      context: context,
      builder: (_) => const _InviteDialog(),
    );
    if (email == null || !context.mounted) return;
    try {
      await ref.read(addCodeMemberProvider)(projectId, email);
      if (!context.mounted) return;
      ToastScope.show(
        context,
        ToastSpec(
          message: '$email is in the project.',
          severity: ToastSeverity.success,
        ),
      );
    } on Object catch (error) {
      if (!context.mounted) return;
      ToastScope.show(
        context,
        ToastSpec(message: '$error', severity: ToastSeverity.error),
      );
    }
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.member});

  final ProjectMember member;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return MetaRow(
      label: member.email ?? 'Someone on this grid',
      value: member.isOwner ? 'Owner' : 'Member',
    );
  }
}

/// Ask for the address to admit.
class _InviteDialog extends StatefulWidget {
  const _InviteDialog();

  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<_InviteDialog> {
  final _email = TextEditingController();

  @override
  void initState() {
    super.initState();
    _email.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return CodeDialog(
      title: 'Invite someone',
      confirmLabel: 'Invite',
      width: 420,
      onConfirm: _email.text.trim().isEmpty
          ? null
          : () => Navigator.of(context).pop(_email.text.trim()),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 6),
          LabeledField(
            label: 'Their email',
            controller: _email,
            hint: 'name@company.com',
            autofocus: true,
          ),
          const SizedBox(height: 14),
          Text(
            'They have to be on this grid already, and to have signed in to it '
            'at least once — the grid only knows people it has seen.',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.45,
              color: AppPalette.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
