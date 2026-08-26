import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../infrastructure/api/models/managed_network.dart';
import '../../../infrastructure/api/models/managed_network_member.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/error_box.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../../shared/widgets/toast.dart';
import '../logic/change_grid_type_controller.dart';
import '../logic/grid_access_types.dart';
import '../logic/invite_email.dart';
import '../logic/member_providers.dart';
import 'general_access_row.dart';
import 'invite_role_picker.dart';
import 'share_banner.dart';
import 'share_grid_people.dart';

/// Everything about who can reach a grid, in one modal — invite someone, see
/// who is already on it, and read (or change) how the grid is reachable in
/// general.
///
/// Opened from both places the old `AddMemberDialog` was: the grid's own header
/// and the sidebar's account menu. One dialog rather than two, so the words and
/// the rules can't drift — and the title names the grid, which the account-menu
/// route had no other way of saying.
///
/// **Modelled on Google Docs' share sheet**, which is the shape non-technical
/// users already know: a full-width address field, the people below it, the
/// blanket rule at the bottom, and one primary button that closes the sheet.
/// Three of its habits are load-bearing here:
///
/// - the address field is the only boxed control, so it is where the eye lands;
/// - a menu lists **labels and a tick**, and the sentence explaining a choice
///   lives in the row that opened it, at dialog width. Grid learned this the
///   hard way: its access menu printed "…can use this grid — includi…";
/// - the role for a person is a noun ("User", "Host"), not a clause.
///
/// One thing is deliberately un-Google: changing the access rule is confirmed
/// before it runs. Docs can flip a document's sharing instantly and harmlessly;
/// changing a grid's rule restarts it under everyone using it, cuts off whoever
/// the new rule excludes, and — for the open rule — stops the grid billing.
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

/// The sheet's width, and the inset every block inside it pays.
///
/// `contentPadding` is zero so the banner and the footer's hairline can run
/// edge to edge; everything else insets itself by [_sheetInset]. The footer
/// takes the same width explicitly, because `AlertDialog` hands its actions to
/// an `OverflowBar` that would let a `Row` stretch to the window and drag the
/// whole dialog wide with it.
const double _sheetWidth = 512;
const double _sheetInset = 24;

class _ShareGridDialogState extends ConsumerState<ShareGridDialog> {
  final _email = TextEditingController();
  final _emailFocus = FocusNode();
  bool _inviting = false;

  /// What the control plane said no to — a 403, a seat cap, a network error.
  /// Cleared the moment the address is edited, since it was about the old one.
  String? _serverError;

  /// What `inviteEmailError` says about the text in the field, once the user
  /// has finished a first attempt at it. Null until [_showErrors].
  String? _localError;

  /// Whether validation is allowed to speak yet.
  ///
  /// False while the address is being typed for the first time: every half-typed
  /// address is invalid, so live checking from keystroke one would sit there
  /// scolding someone who is doing nothing wrong. It flips on the first blur or
  /// the first Invite — after that the verdict updates on every keystroke, so it
  /// disappears the instant the address becomes usable.
  bool _showErrors = false;

  /// The one message the field shows. A server refusal outranks a syntax
  /// complaint: it is the newer fact, and it is about an address the client
  /// already accepted.
  String? get _error => _serverError ?? _localError;

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
  void initState() {
    super.initState();
    // The access controller outlives the sheet, so a rule picked and then
    // abandoned — Esc, Done, a click outside — would still be sitting there
    // "not saved yet" the next time anyone opens this dialog, on any grid.
    //
    // Post-frame, not inline: touching a provider during `initState` mutates
    // state while the tree is building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = ref.read(changeGridTypeControllerProvider);
      // Applying is left alone: that request is in flight and owns its own
      // state until it lands.
      if (state is ChangeGridTypeConfirming || state is ChangeGridTypeFailed) {
        ref.read(changeGridTypeControllerProvider.notifier).cancel();
      }
    });
  }

  @override
  void dispose() {
    _email.dispose();
    _emailFocus.dispose();
    super.dispose();
  }

  /// Re-runs the address check, once [_showErrors] has let it speak.
  void _revalidate() {
    if (!_showErrors) return;
    final next = inviteEmailError(_email.text.trim());
    if (next != _localError) setState(() => _localError = next);
  }

  /// Leaving the field is a finished attempt — but only if there is something
  /// in it. Blurring an empty box is someone clicking elsewhere, not someone
  /// failing to type an address.
  void _onFocusChange(bool hasFocus) {
    if (hasFocus || _email.text.trim().isEmpty) return;
    setState(() {
      _showErrors = true;
      _localError = inviteEmailError(_email.text.trim());
    });
  }

  Future<void> _invite() async {
    final email = _email.text.trim();
    // Checked here, not only on the server: a 422 comes back as one flat
    // "Invalid email", while `inviteEmailError` names the half that is broken.
    // The request is never sent when the client already knows the answer.
    final invalid = inviteEmailError(email);
    if (invalid != null) {
      setState(() {
        _showErrors = true;
        _localError = invalid;
        _serverError = null;
      });
      _emailFocus.requestFocus();
      return;
    }

    setState(() {
      _inviting = true;
      _serverError = null;
      _localError = null;
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
        _serverError = error;
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
      // The next address starts clean: the field is empty again, and an empty
      // field has not been got wrong yet.
      _showErrors = false;
      _localError = null;
    });
    ToastScope.show(
      context,
      ToastSpec(message: 'Invited $email.', severity: ToastSeverity.success),
    );
  }

  /// Sends the access rule the owner picked, then tells them it landed.
  Future<void> _applyAccessChange(ManagedNetworkType target) async {
    final domain = ref.read(gridDomainProvider).value;
    final failure = await ref
        .read(changeGridTypeControllerProvider.notifier)
        .apply(networkId: _networkId, target: target);
    if (!mounted || failure != null) return;
    ToastScope.show(
      context,
      ToastSpec(
        message:
            'This grid is now “${accessLabelFor(target, domain: domain)}”.',
        severity: ToastSeverity.success,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final change = ref.watch(changeGridTypeControllerProvider);
    final domain = ref.watch(gridDomainProvider).value;

    return AlertDialog(
      // Deliberately **not** `scrollable: true` — the same trap
      // [ConnectorDetailsDialog] carries a note about, and this dialog walked
      // straight into it. That flag wraps the content in an `IntrinsicWidth`,
      // which asks every child for its natural height; the people list is a
      // `ListView` and cannot answer. The result was a relayout that re-entered
      // the mouse tracker's device-update phase every frame — the app froze on
      // open, spewing `!_debugDuringDeviceUpdate`.
      //
      // The one part that can outgrow the window scrolls on its own instead;
      // see [SharePeopleList.maxHeight].
      // The 14 on the right was room for a help glyph that is no longer there.
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      title: Text('Who can use “${widget.network.name}”'),
      // Zero, so the banner and the footer's hairline run the full width of the
      // sheet the way Docs draws them. Every block below pays its own inset.
      contentPadding: EdgeInsets.zero,
      content: SizedBox(
        width: _sheetWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_bannerFor(change, domain) case final banner?)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                child: banner,
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _InviteField(
                    controller: _email,
                    focusNode: _emailFocus,
                    enabled: !_inviting,
                    hasError: _error != null,
                    onSubmitted: _invite,
                    onFocusChange: _onFocusChange,
                    onChanged: () {
                      // The refusal was about the address that has just been
                      // edited, so it is out of date the moment a key lands.
                      if (_serverError != null) {
                        setState(() => _serverError = null);
                      }
                      _revalidate();
                    },
                  ),
                  // The role and the send button appear only once there is
                  // something to send — Docs' own behaviour, and what gives the
                  // address field the whole width it needs.
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _email,
                    builder: (context, value, _) {
                      if (value.text.trim().isEmpty) {
                        return const SizedBox.shrink();
                      }
                      return _InviteActions(
                        role: _effectiveRole,
                        roles: _grantable,
                        inviting: _inviting,
                        onRoleChanged: (role) => setState(() => _role = role),
                        onInvite: _invite,
                      );
                    },
                  ),
                  if (_error case final message?) ...[
                    const SizedBox(height: 12),
                    ErrorBox(message: message, maxHeight: 96),
                  ],
                  const _Heading('Members'),
                  // Removing is the owner's alone — see
                  // [SharePeopleList.canRemove]. `widget.network.isOwner` is
                  // about *this viewer*, not about the people in the rows.
                  SharePeopleList(
                    networkId: _networkId,
                    canRemove: widget.network.isOwner,
                    grantable: _grantable,
                  ),
                  const _Heading('Who can join'),
                  GeneralAccessRow(network: widget.network),
                  const SizedBox(height: 20),
                ],
              ),
            ),
            Divider(height: 1, thickness: 1, color: AppPalette.divider),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(24, 14, 24, 18),
      actions: [
        SizedBox(
          width: _sheetWidth - _sheetInset * 2,
          child: _Footer(change: change, onApply: _applyAccessChange),
        ),
      ],
    );
  }

  /// The strip under the title: what is about to happen, or what is happening.
  ///
  /// Nothing else earns this slot. An invite failure belongs beside the field
  /// that caused it, and a failed rule change beside the rule.
  Widget? _bannerFor(ChangeGridTypeState state, String? domain) =>
      switch (state) {
        ChangeGridTypeConfirming(:final target) => ShareBanner(
          tone: ShareBannerTone.warning,
          icon: LucideIcons.triangleAlert300,
          message: accessChangeWarning(target, domain: domain),
        ),
        ChangeGridTypeApplying() => ShareBanner(
          icon: LucideIcons.refreshCw300,
          message:
              '${widget.network.name} is restarting on the new rule. '
              'Everyone on it reconnects in a few seconds.',
        ),
        _ => null,
      };
}

/// The address field: full width, and the only boxed control in the sheet.
class _InviteField extends StatelessWidget {
  const _InviteField({
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.hasError,
    required this.onSubmitted,
    required this.onChanged,
    required this.onFocusChange,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final bool hasError;
  final VoidCallback onSubmitted;
  final VoidCallback onChanged;

  /// Leaving the field counts as a finished attempt — see `_onFocusChange`.
  final ValueChanged<bool> onFocusChange;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const FieldLabel('Invite people'),
        Focus(
          onFocusChange: onFocusChange,
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            enabled: enabled,
            autofocus: true,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => onSubmitted(),
            onChanged: (_) => onChanged(),
            style: const TextStyle(fontSize: 14, height: 1.4),
            decoration: _decoration(hasError),
          ),
        ),
      ],
    );
  }

  /// The app's field, plus the one hairline the design system's "no borders"
  /// rule has to give way for.
  ///
  /// Measured: `AppCard.inset` on this dialog's own surface is **1.065:1** in
  /// dark and **1.073:1** in light — a fill that cannot separate a layer, which
  /// §2 says is exactly when a border or a shadow has to. A shadow would read
  /// as a raised block; this box is recessed, so it takes the rim instead, and
  /// [AppCard.insetHair] is the token already made for it. Scoped to this one
  /// field on purpose — it is the sheet's entry point, and Docs boxes the same
  /// one for the same reason.
  InputDecoration _decoration(bool hasError) {
    final base = labeledFieldDecoration(
      'Email address',
      fill: AppCard.inset,
      hasError: hasError,
    );
    if (hasError) return base;
    return base.copyWith(
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: AppCard.insetHair),
      ),
    );
  }
}

/// The role for this invite and the button that sends it — shown only once an
/// address has been typed.
class _InviteActions extends StatelessWidget {
  const _InviteActions({
    required this.role,
    required this.roles,
    required this.inviting,
    required this.onRoleChanged,
    required this.onInvite,
  });

  final ManagedMemberRole role;
  final List<ManagedMemberRole> roles;
  final bool inviting;
  final ValueChanged<ManagedMemberRole> onRoleChanged;
  final VoidCallback onInvite;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              InviteRolePicker(
                value: role,
                roles: roles,
                enabled: !inviting,
                onChanged: onRoleChanged,
              ),
              const Spacer(),
              FilledButton(
                onPressed: inviting ? null : onInvite,
                child: inviting
                    ? const AppSpinner.onAccent()
                    : const Text('Invite'),
              ),
            ],
          ),
          // Under the role rather than beside it: a sentence squeezed into
          // what is left of the row wraps to three ragged lines caught between
          // two controls, and it explains the control on its left, so it reads
          // better hanging under it.
          Padding(
            padding: const EdgeInsets.only(left: 10, top: 6, right: 4),
            child: Text(
              role.description,
              style: TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The sheet's bottom bar.
///
/// Docs closes with a single **Done** that saves nothing — every action above
/// took effect when it was pressed. Grid keeps that, and grows a Save only for
/// the one thing here that is *not* immediate: the access rule, which is
/// confirmed before it restarts the grid.
class _Footer extends StatelessWidget {
  const _Footer({required this.change, required this.onApply});

  final ChangeGridTypeState change;
  final ValueChanged<ManagedNetworkType> onApply;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Consumer(
      builder: (context, ref, _) => Row(
        children: [
          const Spacer(),
          ...switch (change) {
            ChangeGridTypeConfirming(:final target) => [
              TextButton(
                // Drops the unsaved rule and shuts the sheet. Cancelling only
                // the change left the user looking at the dialog they had just
                // backed out of, with nothing to show for the press — and the
                // controller is app-wide, so a pending rule left behind would
                // be waiting the next time the sheet opened.
                onPressed: () {
                  ref.read(changeGridTypeControllerProvider.notifier).cancel();
                  Navigator.of(context).pop();
                },
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => onApply(target),
                child: const Text('Save'),
              ),
            ],
            ChangeGridTypeApplying() => [
              const FilledButton(onPressed: null, child: AppSpinner.onAccent()),
            ],
            _ => [
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ],
          },
        ],
      ),
    );
  }
}

/// A section title inside the sheet.
class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.only(top: 22, bottom: 8),
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
