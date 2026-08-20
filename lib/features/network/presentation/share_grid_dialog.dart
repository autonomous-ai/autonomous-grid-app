import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/managed_network_member.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/error_box.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../../shared/widgets/toast.dart';
import '../logic/grid_access.dart';
import '../logic/invite_email.dart';
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
  bool _inviting = false;
  String? _error;

  String get _networkId => widget.network.networkId;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _invite() async {
    final email = _email.text.trim();
    final invalid = inviteEmailError(email);
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }

    setState(() {
      _inviting = true;
      _error = null;
    });

    // Always `both` while the role picker is hidden: it is the choice the
    // picker defaulted to, and the widest one — a person invited to use the
    // grid and to share a machine with it can do either or neither, whereas
    // guessing narrower would silently withhold something the inviter meant to
    // give. Restore the picker and this reads `_role.wire` again.
    final error = await ref.read(addMemberActionProvider)(
      networkId: _networkId,
      email: email,
      roles: [ManagedMemberRole.both.wire],
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
            // [FieldLabel] + a hand-built field rather than [LabeledField],
            // which stacks its own label above its own box: inside a Row the
            // button would then centre against label *and* field and sit too
            // high. This is the split the label was extracted for.
            const FieldLabel('Add people'),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _email,
                    enabled: !_inviting,
                    autofocus: true,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.done,
                    // Enter still sends. The button is what says so now — a
                    // line of prose explaining how to submit a form is a
                    // missing button with extra steps.
                    onSubmitted: (_) => _invite(),
                    // Validation fires on submit, never per keystroke: every
                    // half-typed address is invalid, so live checking would sit
                    // there scolding from the first character. But once a
                    // verdict is on screen it clears the moment the user starts
                    // fixing it — an error that outlives the mistake reads as
                    // the app being stuck. Guarded, so the common case (no
                    // error) costs no rebuild.
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                    style: const TextStyle(fontSize: 14, height: 1.4),
                    // The field sits on the dialog's raised surface, not the
                    // page, so the page-tuned default fill would measure
                    // 1.023:1 against it in dark and vanish. See
                    // [labeledFieldDecoration].
                    decoration: labeledFieldDecoration(
                      'teammate@example.com',
                      fill: AppCard.inset,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // Rebuilt on every keystroke, but only this subtree — the
                // button has to dim while the field is empty (that dimming is
                // the affordance the prose line was standing in for) and
                // `setState` on the dialog would rebuild the members list under
                // it for nothing.
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _email,
                  builder: (context, value, _) => FilledButton(
                    onPressed: _inviting || value.text.trim().isEmpty
                        ? null
                        : _invite,
                    child: _inviting
                        ? const AppSpinner.onAccent()
                        : const Text('Invite'),
                  ),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              ErrorBox(message: _error!, maxHeight: 96),
            ],
            const _Heading('People with access'),
            // Removing is the owner's alone — see [SharePeopleList.canRemove].
            // `widget.network.isOwner` is about *this viewer*, not about the
            // people in the rows.
            SharePeopleList(
              networkId: _networkId,
              canRemove: widget.network.isOwner,
            ),
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
/// Deliberately short, but not shortened past the truth: `permissionless` opens
/// *using* the grid to anyone while still gating who may share a computer to
/// it, so that one keeps its second clause. Collapsing it
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
