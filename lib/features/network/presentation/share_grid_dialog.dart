import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/managed_network_member.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_select_field.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/error_box.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../../shared/widgets/toast.dart';
import '../logic/grid_access.dart';
import '../logic/member_providers.dart';
import 'share_grid_people.dart';

/// Everything about who can reach a grid, in one modal — invite someone, see
/// who is already on it, and read how the grid is reachable in general.
///
/// Replaces the old one-field `AddMemberDialog`, and is opened from both places
/// that used it: the grid's own header and the sidebar's account menu. One
/// dialog rather than two, so the words and the rules can't drift — and the
/// title names the grid, which the account-menu route had no other way of
/// saying.
///
/// Modelled on Google Drive's share sheet because that shape is the one
/// non-technical users already know: add at the top, the list of people in the
/// middle, the blanket rule at the bottom. **The bottom section is a sentence,
/// not a control** — see [_GeneralAccess].
class ShareGridDialog extends ConsumerStatefulWidget {
  const ShareGridDialog({super.key, required this.network});

  final NetworkCredential network;

  static Future<void> show(BuildContext context, NetworkCredential network) {
    return showDialog<void>(
      context: context,
      builder: (_) => ShareGridDialog(network: network),
    );
  }

  @override
  ConsumerState<ShareGridDialog> createState() => _ShareGridDialogState();
}

class _ShareGridDialogState extends ConsumerState<ShareGridDialog> {
  final _email = TextEditingController();
  ManagedMemberRole _role = ManagedMemberRole.both;
  bool _inviting = false;
  String? _error;

  /// What the invite row is showing: empty until someone types, so the resting
  /// dialog is a single field rather than a form.
  bool _typing = false;

  String get _networkId => widget.network.networkId;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _invite() async {
    final email = _email.text.trim();
    if (!looksLikeEmail(email)) {
      setState(() => _error = 'Enter a valid email address.');
      return;
    }

    setState(() {
      _inviting = true;
      _error = null;
    });

    final error = await ref.read(addMemberActionProvider)(
      networkId: _networkId,
      email: email,
      roles: [_role.wire],
    );

    if (!mounted) return;
    if (error != null) {
      setState(() {
        _inviting = false;
        _error = error;
      });
      return;
    }

    // The dialog stays open on purpose: the person lands in the list right
    // below, which is the whole reason the invite and the list share a modal.
    // Inviting two people in a row was two round trips through a menu before.
    ref.invalidate(networkMembersProvider(_networkId));
    setState(() {
      _inviting = false;
      _typing = false;
      _email.clear();
    });
    ToastScope.show(
      context,
      ToastSpec(message: 'Invited $email.', severity: ToastSeverity.success),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return AlertDialog(
      // Deliberately **not** `scrollable: true` — the same trap
      // [ConnectorDetailsDialog] carries a note about, and this dialog walked
      // straight into it. That flag wraps the content in an `IntrinsicWidth`,
      // which asks every child for its natural height; the people list is a
      // `ListView` and cannot answer, and `AppSelectField` is a `LayoutBuilder`
      // that cannot either. The result was a relayout that re-entered the
      // mouse tracker's device-update phase every frame — the app froze on
      // open, spewing `!_debugDuringDeviceUpdate`.
      //
      // The one part that can outgrow the window scrolls on its own instead;
      // see [SharePeopleList.maxHeight].
      title: Text('Share “${widget.network.name}”'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LabeledField(
              label: 'Add people',
              controller: _email,
              hint: 'teammate@example.com',
              enabled: !_inviting,
              autofocus: true,
              // The field sits on the dialog's raised surface, not the page, so
              // the page-tuned default fill would measure 1.023:1 against it in
              // dark and vanish. See [LabeledField.fill].
              fill: AppCard.inset,
              onChanged: (value) {
                final typing = value.trim().isNotEmpty;
                if (typing != _typing) setState(() => _typing = typing);
              },
              onSubmitted: (_) => _invite(),
            ),
            // Google reveals the role picker and Send only once there is
            // someone to send to. Same here: a resting dialog that is one field
            // reads as "type an email", which is what it wants.
            if (_typing) ...[
              const SizedBox(height: 10),
              _InviteControls(
                role: _role,
                busy: _inviting,
                onRole: (role) => setState(() => _role = role),
                onInvite: _invite,
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              ErrorBox(message: _error!, maxHeight: 96),
            ],
            const _Heading('People with access'),
            SharePeopleList(networkId: _networkId),
            const _Heading('General access'),
            _GeneralAccess(network: widget.network),
          ],
        ),
      ),
      // No footer at all. Google's two buttons don't survive the translation:
      // "Copy link" has nothing behind it here (Grid invites by email; there
      // is no link), and "Done" confirmed nothing — every action in this
      // dialog already took effect the moment it was pressed. A button that
      // only closes a window is a button the window's own dismiss already is.
      //
      // Esc and a click outside still close it — `showDialog` gives both.
      //
      // TODO(BE): Google's "Copy link" has no counterpart until there is an
      // invite link — a token someone can be sent that joins them to the grid.
      // Membership is by email only today, so there is nothing to copy.
      // `.claude/share-grid-plan.md` §7.
    );
  }
}

/// The row that appears under the email field: what the invited person may do,
/// and the button that sends it.
class _InviteControls extends StatelessWidget {
  const _InviteControls({
    required this.role,
    required this.busy,
    required this.onRole,
    required this.onInvite,
  });

  final ManagedMemberRole role;
  final bool busy;
  final ValueChanged<ManagedMemberRole> onRole;
  final VoidCallback onInvite;

  /// The three roles the control plane accepts, in plain language. `admin` is
  /// absent because the API rejects it — the owner is the only one.
  static const _options = [
    AppSelectOption(
      value: ManagedMemberRole.both,
      label: 'Use and share',
      detail: 'Send work to the grid, and share their computer with it',
    ),
    AppSelectOption(
      value: ManagedMemberRole.consumer,
      label: 'Use models only',
      detail: 'Send work to the grid',
    ),
    AppSelectOption(
      value: ManagedMemberRole.provider,
      label: 'Share a computer only',
      detail: 'Let this grid run work on their computer',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      children: [
        Expanded(
          child: AppSelectField<ManagedMemberRole>(
            label: 'They can',
            showLabel: false,
            value: role,
            options: _options,
            // Each role's detail is a clause, and this field shares its row
            // with the Invite button — so the closed field clipped it to
            // "Send work to the grid, an…". The menu shows it whole, which is
            // where it's read anyway. Google shows the role name alone here too.
            showDetailInField: false,
            fill: AppCard.inset,
            onChanged: onRole,
          ),
        ),
        const SizedBox(width: 10),
        FilledButton(
          onPressed: busy ? null : onInvite,
          child: busy ? const AppSpinner.onAccent() : const Text('Invite'),
        ),
      ],
    );
  }
}

/// The blanket rule: who can reach this grid without being on the list above.
///
/// One sentence, no control. The three modes are real — they are exactly how
/// the control plane labels a grid — but `network_type` is set at
/// `POST /managed-networks` and the only PATCH the app has takes `name`, so
/// there is nothing to send. A picker here could be changed and never saved,
/// which cost the dialog a yellow "not saved" line whose whole job was to
/// contradict the field above it. See `.claude/share-grid-plan.md` §2.1.
///
/// It stays *visible* rather than being dropped: whether a grid is invite-only
/// or open to anyone signed in is the fact that decides how carefully you pick
/// who to add, and it is not readable anywhere else in this dialog.
///
/// TODO(BE): restore a picker here once `PATCH /v1/grid/networks/{id}` accepts
/// `network_type`. Until then the app cannot fake it — access is enforced by
/// the relay, and `~/.grid/credentials.toml` is a local cache the CLI owns, so
/// writing a mode into it would change this sentence and nothing else.
/// `.claude/share-grid-plan.md` §2.1.
class _GeneralAccess extends ConsumerWidget {
  const _GeneralAccess({required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    return Text(
      _accessSummary(gridAccessFor(network.networkType)),
      style: TextStyle(
        color: AppPalette.textSecondary,
        fontSize: 12.5,
        height: 1.4,
      ),
    );
  }
}

/// What the mode permits, in one line.
///
/// [GridAccess.domain] says the same as [GridAccess.restricted] on purpose. It
/// used to claim "anyone with an @autonomous.ai email can use this grid", which
/// was **wrong** — an invention read off the wire value's name rather than off
/// anything the product does. A `private-domain` grid is the organisation's own
/// grid; the domain names *whose* grid it is, not who may walk into it.
/// Membership is still the list above, exactly as for a private grid, which is
/// also why `NetworkCredential.isPublic` has always resolved it to Private.
///
/// Deliberately short, but not shortened past the truth: `permissioned-
/// providers` opens *using* the grid to anyone while still gating who may
/// share a computer to it, so that one keeps its second clause. Collapsing it
/// to "anyone can use this grid" would read as "anyone can put a machine on
/// it", which is a different and much larger promise.
String _accessSummary(GridAccess access) => switch (access) {
  GridAccess.restricted ||
  GridAccess.domain => 'Only the people listed above can use this grid.',
  GridAccess.anyone =>
    'Anyone signed in to Grid can use this grid. Only the people listed '
        'above can share a computer with it.',
};

/// A section title inside the dialog.
class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.only(top: 22, bottom: 10),
      child: Text(
        text,
        style: TextStyle(
          color: AppPalette.textPrimary,
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
