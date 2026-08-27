import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../infrastructure/api/models/managed_network.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/error_box.dart';
import '../../auth/logic/session_controller.dart';
import '../logic/change_grid_type_controller.dart';
import '../logic/grid_access.dart';
import '../logic/grid_access_types.dart';
import 'access_menu.dart';

/// "General access" — who can reach this grid without being on the list above.
///
/// Built like Google Drive's equivalent row: a round badge whose glyph says at
/// a glance how open this is, and the rule itself as a menu trigger with one
/// plain sentence under it.
///
/// **Drive's third column is deliberately not here.** Drive puts a role picker
/// at the trailing edge ("Viewer") because on a document that IS a control —
/// the owner sets what link-holders get. Grid has nothing to set: what a
/// non-member gets is decided by the rule, so the same slot could only hold a
/// word. Sitting where every other row in this sheet carries a menu, a word
/// reads as a control that has stopped working. And the word it held was wrong
/// on the domain rule, which is worse than useless — see [accessRowDescription].
///
/// The sentence lives **here**, not in the menu. A menu is as wide as its
/// button; a row is as wide as the dialog. Putting it inside the menu is what
/// left Grid printing "…can use this grid — includi…" on the one control that
/// decides who reaches the grid at all.
///
/// Picking a rule does not send anything: [ChangeGridTypeController] moves to
/// confirming, the sheet raises a warning banner, and the footer grows a Save.
class GeneralAccessRow extends ConsumerWidget {
  const GeneralAccessRow({super.key, required this.network});

  final NetworkCredential network;

  static const double _menuWidth = 244;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    // ⚠️ **Read the rule from the store, not from [network].** That field is a
    // snapshot taken when the dialog was OPENED — `ShareGridDialog.show` is
    // handed a NetworkCredential and holds it — so it cannot change while the
    // dialog is up. A change that succeeded then left this row on the old rule,
    // and it only looked right after closing and reopening: the change reads as
    // having silently failed, which is the exact impression the `grid sync` in
    // `ChangeGridTypeController.apply` was added to prevent. That sync does its
    // half (credentials.toml is rewritten and `sessionProvider` invalidated);
    // nothing was watching it here.
    //
    // Falls back to the snapshot rather than vanishing when the grid is not in
    // the file — `grid sync` rewrites it, and a read landing mid-write must not
    // blank the section.
    final live =
        ref.watch(sessionProvider).byName(network.networkId) ?? network;
    final current = ManagedNetworkType.fromWire(live.networkType);

    // Not the owner, or a rule this picker doesn't offer
    // (`permissionless` on an old grid, `private-domain`): a sentence, not a
    // control. A menu that cannot save is worse than none — it looks like it
    // worked.
    if (!live.isOwner || current == null) {
      final access = gridAccessFor(live.networkType);
      if (access == GridAccess.domain) {
        // Named where the app can name it, so a domain grid stops calling
        // itself invite-only — see [_DomainAccess].
        return _DomainAccess(network: live);
      }
      return _AccessBody(
        icon: _readOnlyIcon(access),
        label: _readOnlyLabel(access),
        description: _readOnlySummary(access),
      );
    }
    return _OwnerAccess(network: live, current: current);
  }
}

/// A grid gated by email domain, for a viewer who cannot change it.
///
/// Its own widget because it is the one read-only rule that was being reported
/// **wrong**. The row said "Invite only / Only the people listed above can use
/// this grid" — but nobody invited these people: the control plane admits every
/// account on the gated domain as a synthetic `both` member (`list_grid_members`
/// in `grid_networks/store.py`), which on the live autonomous.ai grid was 13 of
/// the 14 accounts using it. A rule that hands out hosting to a whole company
/// must not read as the tightest setting the app has.
class _DomainAccess extends StatelessWidget {
  const _DomainAccess({required this.network});

  final NetworkCredential network;

  @override
  Widget build(BuildContext context) {
    final domain = gatedDomainFor(
      networkType: network.networkType,
      name: network.name,
    );
    // The same two strings the owner's picker uses, so the sentence a member
    // reads and the one an owner picks cannot drift apart.
    return _AccessBody(
      icon: LucideIcons.building2300,
      label: domain == null
          ? 'One email domain'
          : accessLabelFor(ManagedNetworkType.domain, domain: domain),
      description: domain == null
          ? 'Only people on this grid’s email domain can use it, or start '
                'an AI node to power it.'
          : accessRowDescription(ManagedNetworkType.domain, domain: domain),
    );
  }
}

/// The owner's control over the rule, and the rule they have picked but not yet
/// saved.
class _OwnerAccess extends ConsumerWidget {
  const _OwnerAccess({required this.network, required this.current});

  final NetworkCredential network;
  final ManagedNetworkType current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final state = ref.watch(changeGridTypeControllerProvider);
    final applying = state is ChangeGridTypeApplying;
    final domain = ref.watch(gridDomainProvider).value;

    // The row shows what was PICKED, not what is saved — a control that snaps
    // back the moment you choose reads as the click not having registered. The
    // banner above and the footer below are what say it hasn't taken effect.
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
        _AccessBody(
          icon: _typeIcon(shown),
          description: accessRowDescription(shown, domain: domain),
          control: AccessMenuButton(
            label: accessLabelFor(shown, domain: domain),
            strong: true,
            enabled: !applying,
            menuSize: accessMenuSize(
              width: GeneralAccessRow._menuWidth,
              rows: types.length,
            ),
            itemsBuilder: (menu) => [
              for (final type in types)
                AccessMenuRow(
                  label: accessLabelFor(type, domain: domain),
                  selected: type == shown,
                  onTap: () {
                    menu.close();
                    ref
                        .read(changeGridTypeControllerProvider.notifier)
                        .select(target: type, current: current);
                  },
                ),
            ],
          ),
        ),
        if (state is ChangeGridTypeFailed) ...[
          const SizedBox(height: 10),
          ErrorBox(message: state.message, maxHeight: 96),
        ],
      ],
    );
  }
}

/// Badge, rule, sentence, and what an outsider gets — the row's shape, shared
/// by the owner's version and the read-only one so they cannot drift apart.
class _AccessBody extends StatelessWidget {
  const _AccessBody({
    required this.icon,
    required this.description,
    this.label,
    this.control,
  });

  final IconData icon;
  final String description;

  /// The rule as plain text, when there is no menu behind it.
  final String? label;

  /// The rule as a menu trigger, for an owner who can change it.
  final Widget? control;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 36,
          height: 36,
          margin: const EdgeInsets.only(top: 1),
          decoration: BoxDecoration(
            color: AppSurface.accentWash,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 17, color: AppPalette.accentOnSurface),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (control case final widget?)
                widget
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 6, 7, 6),
                  child: Text(
                    label ?? '',
                    style: TextStyle(
                      color: AppPalette.textPrimary,
                      fontSize: 13,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              Padding(
                // Lines up under the trigger's label, not under its box.
                padding: const EdgeInsets.only(left: 10, right: 4, top: 2),
                child: Text(
                  description,
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The glyph that says how open a grid is before the label is read.
IconData _typeIcon(ManagedNetworkType type) => switch (type) {
  ManagedNetworkType.restricted => LucideIcons.lock300,
  ManagedNetworkType.domain => LucideIcons.building2300,
  ManagedNetworkType.anyone => LucideIcons.globe300,
};

/// The glyph for a rule the picker doesn't offer. [GridAccess.domain] never
/// reaches here — it has [_DomainAccess] — but the switch stays exhaustive so
/// adding a rule is a compile error rather than a silent lock icon.
IconData _readOnlyIcon(GridAccess access) => switch (access) {
  GridAccess.restricted => LucideIcons.lock300,
  GridAccess.domain => LucideIcons.building2300,
  GridAccess.anyone => LucideIcons.globe300,
};

/// What to call a rule the picker doesn't offer, for the row's own label.
String _readOnlyLabel(GridAccess access) => switch (access) {
  GridAccess.restricted => 'Invite only',
  GridAccess.domain => 'One email domain',
  GridAccess.anyone => 'Public',
};

/// What the rule permits, in one line — for a member who cannot change it and
/// for the two rules this picker does not offer.
///
/// [GridAccess.domain] says the same as [GridAccess.restricted] on purpose. It
/// used to claim "anyone with an @autonomous.ai email can use this grid", which
/// was **wrong** for `private-domain` — an invention read off the wire value's
/// name. That grid is the organisation's own; the domain names *whose* grid it
/// is, not who may walk into it.
String _readOnlySummary(GridAccess access) => switch (access) {
  GridAccess.restricted || GridAccess.domain =>
    'Only the people listed above can use this grid, or start an AI node '
        'to power it.',
  GridAccess.anyone =>
    'Anyone can use it. Only the people above can start an AI node to '
        'power it.',
};
