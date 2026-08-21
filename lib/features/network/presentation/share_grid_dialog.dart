import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/managed_network_member.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/error_box.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../../shared/widgets/toast.dart';
import '../../../infrastructure/api/models/managed_network.dart';
import '../logic/change_grid_type_controller.dart';
import '../logic/grid_access.dart';
import '../logic/grid_access_types.dart';
import '../logic/invite_email.dart';
import '../logic/member_providers.dart';
import 'grid_type_picker.dart';
import 'invite_role_picker.dart';
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

  /// What the invited person will be able to do. Defaults to the widest grant —
  /// see [ManagedMemberRole.fallback].
  ManagedMemberRole _role = ManagedMemberRole.fallback;

  /// The roles this viewer may hand out. Never offer a grant they do not hold:
  /// the control plane refuses it (403 `role_above_caller`), and a choice that
  /// 403s after the fact reads as a bug rather than as a rule.
  List<ManagedMemberRole> get _grantable =>
      invitableRolesFor(widget.network.roles);

  /// [_role], clamped to what this viewer may actually grant.
  ///
  /// A getter rather than a correction written into [_role] during `build`:
  /// mutating state there is a side effect in a method that may run twice, and
  /// the clamp has to hold for the send too — one place, read by both.
  ManagedMemberRole get _effectiveRole =>
      _grantable.contains(_role) ? _role : _grantable.first;

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

    final error = await ref.read(addMemberActionProvider)(
      networkId: _networkId,
      email: email,
      roles: [_effectiveRole.wire],
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
                // Beside the address, the way Drive puts it: the role belongs to
                // the person being typed in, and a picker further down would read
                // as a setting for the grid instead. Fixed width so the field
                // does not resize as the label changes length.
                SizedBox(
                  // Sized to the longest label ("Use + run models") plus the
                  // caret. The email field is Expanded, so it yields the space.
                  // Measured against "Can use and share", one character wider
                  // than today's longest — so this still has room, and a new
                  // label longer than that one needs the width re-measured.
                  width: 196,
                  child: InviteRolePicker(
                    value: _effectiveRole,
                    roles: _grantable,
                    enabled: !_inviting,
                    onChanged: (value) => setState(() => _role = value),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _effectiveRole.description,
                    style: TextStyle(
                      color: AppPalette.textSecondary,
                      fontSize: 12.5,
                      height: 1.4,
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
    final current = ManagedNetworkType.fromWire(network.networkType);

    // Not the owner, or a rule this picker doesn't offer
    // (`permissioned-providers`, `private-domain`): a sentence, not a control.
    // A picker that cannot save is worse than none — it looks like it worked.
    if (!network.isOwner || current == null) {
      return Text(
        _accessSummary(gridAccessFor(network.networkType)),
        style: TextStyle(
          color: AppPalette.textSecondary,
          fontSize: 12.5,
          height: 1.4,
        ),
      );
    }
    return _AccessRulePicker(network: network, current: current);
  }
}

/// The owner's control over who can reach the grid.
class _AccessRulePicker extends ConsumerWidget {
  const _AccessRulePicker({required this.network, required this.current});

  final NetworkCredential network;
  final ManagedNetworkType current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(changeGridTypeControllerProvider);
    final applying = state is ChangeGridTypeApplying;
    final domain = ref.watch(gridDomainProvider).value;
    // The field shows what was PICKED, not what is saved — a select that snaps
    // back to the old value the moment you choose reads as the click not having
    // registered. The confirmation below is what says it has not taken effect
    // yet, and Cancel puts the field back.
    final shown = switch (state) {
      ChangeGridTypeConfirming(:final target) => target,
      ChangeGridTypeApplying(:final target) => target,
      _ => current,
    };
    // The rule this grid is already on stays listed even when the account can
    // no longer choose it — an owner whose address moved to a public provider
    // would otherwise find their current setting missing, and no way off it.
    final types = {
      ...accessTypesFor(canRestrictToDomain: domain != null),
      current,
    }.toList()..sort((a, b) => a.index.compareTo(b.index));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GridTypePicker(
          label: '',
          fill: AppCard.inset,
          domain: domain,
          value: shown,
          types: types,
          enabled: !applying,
          onChanged: (next) => ref
              .read(changeGridTypeControllerProvider.notifier)
              .select(target: next, current: current),
        ),
        const SizedBox(height: 8),
        Text(
          accessDescriptionFor(shown, domain: domain),
          style: TextStyle(
            color: AppPalette.textSecondary,
            fontSize: 12.5,
            height: 1.4,
          ),
        ),
        if (state is ChangeGridTypeConfirming)
          _ConfirmChange(
            network: network,
            target: state.target,
            domain: domain,
          ),
        if (applying) ...[
          const SizedBox(height: 10),
          Text(
            'Changing to “${accessLabelFor(state.target, domain: domain)}”… '
            'the grid restarts, so it is unavailable for a few seconds.',
            style: TextStyle(
              color: AppPalette.textSecondary,
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
        ],
        if (state is ChangeGridTypeFailed) ...[
          const SizedBox(height: 10),
          ErrorBox(message: state.message, maxHeight: 96),
        ],
      ],
    );
  }
}

/// What the owner is about to give up, and the button that does it.
class _ConfirmChange extends ConsumerWidget {
  const _ConfirmChange({
    required this.network,
    required this.target,
    required this.domain,
  });

  final NetworkCredential network;
  final ManagedNetworkType target;
  final String? domain;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Change to “${accessLabelFor(target, domain: domain)}”?',
            style: TextStyle(
              color: AppPalette.textPrimary,
              fontSize: 13,
              fontWeight: AppFont.medium,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${accessDescriptionFor(target, domain: domain)} '
            '${_costOf(target)}',
            style: TextStyle(
              color: AppPalette.textSecondary,
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => ref
                    .read(changeGridTypeControllerProvider.notifier)
                    .cancel(),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => _apply(context, ref),
                child: const Text('Change'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _apply(BuildContext context, WidgetRef ref) async {
    final failure = await ref
        .read(changeGridTypeControllerProvider.notifier)
        .apply(networkId: network.networkId, target: target);
    if (!context.mounted || failure != null) return;
    ToastScope.show(
      context,
      ToastSpec(
        message:
            'This grid is now “${accessLabelFor(target, domain: domain)}”.',
        severity: ToastSeverity.success,
      ),
    );
  }
}

/// What the rule permits, in one line — the read-only view, for a member who
/// cannot change it and for the two rules this picker does not offer.
///
/// [GridAccess.domain] says the same as [GridAccess.restricted] on purpose. It
/// used to claim "anyone with an @autonomous.ai email can use this grid", which
/// was **wrong** for `private-domain` — an invention read off the wire value's
/// name. That grid is the organisation's own; the domain names *whose* grid it
/// is. (`domain-restricted`, the rule an owner picks, really is gated by domain
/// — but that one resolves to a [ManagedNetworkType] and never reaches here.)
///
/// Deliberately short, but not shortened past the truth: `permissionless` opens
/// *using* the grid to anyone while still gating who may run a model for
/// it, so that one keeps its second clause. Collapsing it
/// to "anyone can use this grid" would read as "anyone can put a machine on
/// it", which is a different and much larger promise.
String _accessSummary(GridAccess access) => switch (access) {
  GridAccess.restricted ||
  GridAccess.domain => 'Only the people listed above can use this grid.',
  GridAccess.anyone =>
    'Anyone signed in to Grid can use this grid. Only the people listed '
        'above can run a model for it.',
};

/// The part of a switch that nobody expects — what it TAKES rather than gives.
///
/// Every one of the three costs something: two cut people off mid-session, and
/// the open one stops the grid billing for usage, which is a money change no
/// one would guess from the word "anyone".
String _costOf(ManagedNetworkType target) => switch (target) {
  ManagedNetworkType.restricted =>
    'Anyone using it who is not on the list above loses access, and any model '
        'they run for it stops serving. The grid restarts, so everyone '
        'reconnects once.',
  // This used to warn that everyone off the domain lost access "even though
  // they stay on the list". They do not any more — the domain admits, and the
  // list keeps working beside it — so the cost is only for someone who is on
  // neither, which is who a switch away from “Anyone” takes it from.
  ManagedNetworkType.domain =>
    'Anyone using it who is neither on that domain nor on the list above '
        'loses access, and any model they run for it stops serving. The grid '
        'restarts, so everyone reconnects once.',
  ManagedNetworkType.anyone =>
    'Usage on this grid stops being billed, and you can no longer block an '
        'individual person. The grid restarts, so everyone reconnects once.',
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
