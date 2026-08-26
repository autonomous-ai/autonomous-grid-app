import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../features/auth/logic/session_controller.dart';
import '../../../features/network/logic/grid_power_provider.dart' show plural;
import '../../../features/network/logic/member_providers.dart';
import '../../../features/network/presentation/share_grid_dialog.dart';
import '../../../features/provider_node/logic/serving_engines_provider.dart';
import '../../../infrastructure/api/models/managed_network_member.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../theme/app_theme.dart';
import '../../widgets/status_dot.dart';
import '../shell_state.dart';

/// The two ways to make a grid bigger, as one control: a machine, or a person.
///
/// Both halves live in a single shell because they answer the same question —
/// "how do I add to this?" — and a grid is made of exactly these two things. Two
/// free-standing buttons said that less well: they read as two unrelated
/// controls that happened to be adjacent, and the pair kept drifting apart from
/// whatever sat between them.
///
/// It replaces what the bar used to carry on this side: the grid capsule (its
/// figures moved to [AppStatusRail], where a readout belongs) and the invite
/// cluster. What is left up here is only what you press.
///
/// Both halves name an action now — the engine half was "Model engines", a
/// place, until 2026-08-26. It is not "Share a computer": that is the share
/// sheet's grant, and a permission and the screen that exercises it cannot wear
/// one name (§5). What is offered here is models, which is also what the other
/// half's guests come for. But the two are not drawn at the same weight. A bar
/// carries one primary, and inviting is the ask that has to survive a glance;
/// serving is the one a host goes looking for. The engine half is glass, like every other
/// capsule this bar has ever had; the invite half is the one opaque, saturated
/// surface on it. That split is the app's existing rule, not a new one — see
/// the note on the old `_InviteButton`.
///
/// ### Why the shell is recessed and the halves are raised
///
/// The first build had it the other way round: a lifted capsule with two flat
/// halves inside it. It read as *one* control with a coloured end, because only
/// the accent half had a surface — the engine half was transparent, so at rest
/// it was a label with a glyph, not a button.
///
/// [AppSegmented] had already solved this: a recessed track with the chip lifted
/// off it. Depth is what says "object" in this app (§2 — fill alone can't
/// separate two surfaces, shadow can), so both halves have to be the raised
/// thing and the shell has to be the well they sit in. Measured on the bar's own
/// ground, which is [AppPalette.windowBg] because the bar has no fill:
///
/// ```
/// track vs page       1.071 light / 1.167 dark
/// glass chip vs track 1.071 light / 1.071 dark   ← plus cardShadow
/// accent chip vs track 5.151 light / 2.757 dark
/// ```
///
/// The same order as [AppSegmented]'s own figures, and for the same reason those
/// are enough: neither number is large, and neither is doing the work alone.
class GridCtaPair extends ConsumerWidget {
  const GridCtaPair({super.key});

  /// The half, and the shell's inset around it. 24 + 3 either side puts the
  /// control at 30 — the tallest thing on a 46px bar, with 8 clear above and
  /// below. It was the face stack that set this, and the numbers still suit the
  /// two labels that outlived it.
  static const double _halfHeight = 24;
  static const double _shellPad = 3;

  /// Below this both labels go, leaving two glyphs.
  ///
  /// The window's width, not the bar's, for the reason the old invite pill
  /// documented: a `Row` measures its non-flex children against unbounded width
  /// before handing the rest to the `Expanded` header, so this control can never
  /// be told how much room it actually has.
  static const double _labelFrom = 1060;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Const-mounted by [AppTopBar], so the bar's own rebuild stops short of
    // here: without this the halves keep whichever fills they first painted.
    AppTheme.watch(context);
    final grid = ref.watch(selectedNetworkProvider);
    // No grid in scope, nothing to add to. Unmounted rather than disabled, like
    // every other control this bar has carried.
    if (grid == null) return const SizedBox.shrink();

    final showLabels = MediaQuery.sizeOf(context).width >= _labelFrom;
    // For the count in the tooltip, not for anything drawn — the ranking the
    // face stack needed went with the stack.
    final members = ref.watch(networkMembersProvider(grid.networkId)).value;

    return DecoratedBox(
      // A well, not a pill: no rim and no lift, because the two things inside it
      // are what should look raised. A track that lifted too would leave three
      // surfaces stacked on a 46px bar.
      decoration: BoxDecoration(
        color: AppSurface.recess,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.all(_shellPad),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _EnginesHalf(
              showLabel: showLabels,
              canHost: grid.canManageProvider,
            ),
            const SizedBox(width: _shellPad),
            _InviteHalf(grid: grid, members: members, showLabel: showLabels),
          ],
        ),
      ),
    );
  }
}

/// The door to Share models — the only one, now that the sidebar row is gone.
///
/// It carries two things that row used to: it lights when that screen is the one
/// open, and it wears a mark for what this computer is contributing. Dropping
/// the row without moving those would have been a loss of function rather than a
/// tidier rail.
///
/// The mark has two states rather than one, which the sidebar row's did not. A
/// dot that only appeared while serving answered "am I hosting?" with silence
/// the rest of the time, and silence is also what a missing feature looks like.
/// Green says serving, grey says not — and both are true statements a host can
/// act on. Measured on this half's two fills, `textSecondary` is the only
/// neutral in the palette that clears 3:1 in all four combinations
/// (5.56–6.82:1); `offline` and `textFaint` both fall through in light. The off
/// state pays for its legibility in *size* instead, at 5px against green's 6.
class _EnginesHalf extends ConsumerStatefulWidget {
  const _EnginesHalf({required this.showLabel, required this.canHost});

  final bool showLabel;

  /// Whether this user may serve on this grid. A consumer wears no mark: a
  /// permanent "not serving" on somebody who is not allowed to serve reports a
  /// state they cannot act on.
  final bool canHost;

  @override
  ConsumerState<_EnginesHalf> createState() => _EnginesHalfState();
}

class _EnginesHalfState extends ConsumerState<_EnginesHalf> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // Selected, not merely hovered: the half is the nav row's replacement, so
    // "you are here" has to survive the pointer leaving.
    final open = ref.watch(shellSectionProvider) == ShellSection.engines;
    final serving = ref.watch(servingEnginesProvider).isNotEmpty;
    final ink = open ? AppPalette.accentOnSurface : AppPalette.textPrimary;

    return Semantics(
      button: true,
      selected: open,
      label: !widget.canHost
          ? 'Share models'
          : serving
          ? 'Share models, serving now'
          : 'Share models, not serving yet',
      child: Tooltip(
        message: !widget.canHost
            ? 'What this computer shares on this grid'
            : serving
            ? 'This computer is serving on this grid'
            : "This computer isn't serving anything yet",
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => ref
                .read(shellSectionProvider.notifier)
                .select(ShellSection.engines),
            child: AnimatedContainer(
              duration: AppMotion.hover,
              curve: AppMotion.curve,
              height: GridCtaPair._halfHeight,
              padding: EdgeInsets.symmetric(
                horizontal: widget.showLabel ? 11 : 8,
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                // A surface at every state, including rest. Transparent here is
                // what made this read as a label rather than a button.
                //
                // Open is an accent wash *over* that surface. `accentWash`, not
                // `accentWashHover`: the stronger one darkens the ground enough
                // that `accentOnSurface` on it measures 4.46:1 in dark — under
                // §11's floor by a hair, which is the worst kind of miss because
                // it still looks fine. This one lands at 4.94:1 / 4.71:1.
                color: open
                    ? Color.alphaBlend(
                        AppSurface.accentWash,
                        AppGlass.surfaceFill,
                      )
                    : _hovered
                    ? AppGlass.surfaceHoverFill
                    : AppGlass.surfaceFill,
                // The lift is what separates chip from track — the fills alone
                // are 1.071:1 apart.
                boxShadow: AppGlass.cardShadow,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.server300, size: 14, color: ink),
                  if (widget.showLabel) ...[
                    const SizedBox(width: 6),
                    Text(
                      'Share models',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: AppFont.semibold,
                        color: ink,
                      ),
                    ),
                  ],
                  // The mark the sidebar row used to carry. After the label,
                  // not before the glyph: it reports on the thing the label
                  // names, so it reads as a suffix rather than a second icon.
                  if (widget.canHost) ...[
                    const SizedBox(width: 6),
                    StatusDot(
                      color: serving
                          ? AppPalette.online
                          : AppPalette.textSecondary,
                      size: serving ? 6 : 5,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Who is on the grid and the way to add someone — one target, and now one
/// word.
///
/// It used to carry the face stack: four member discs and a "+29", first beside
/// the button and then inside it. Both are gone. The reason the stack was there
/// at all was to say *which* grid an invite would be to, and the status rail
/// answers that now — it names the grid and counts its people a few pixels
/// below. A second telling cost the bar ~90px and made the one saturated
/// surface on it the busiest thing in the window.
///
/// So the label goes back to its long form. "Invite" alone was short because the
/// discs in front of it were already saying who; with nothing in front of it,
/// the verb needs its object — and "Invite members" is the wording the account
/// menu has always used, so the two entry points finally read the same.
class _InviteHalf extends ConsumerStatefulWidget {
  const _InviteHalf({
    required this.grid,
    required this.members,
    required this.showLabel,
  });

  final NetworkCredential grid;

  /// The roster, for the count a screen reader and the tooltip are given. Null
  /// while it loads — and never a gate on the button, because the control plane
  /// can be slow or unreadable and an invite that waited for a list it does not
  /// need would be missing exactly when a new grid has nobody on it yet.
  final List<ManagedNetworkMember>? members;

  final bool showLabel;

  @override
  ConsumerState<_InviteHalf> createState() => _InviteHalfState();
}

class _InviteHalfState extends ConsumerState<_InviteHalf> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final members = widget.members;

    return Semantics(
      button: true,
      label: members == null
          ? 'Invite people to ${widget.grid.name}'
          : 'Invite people to ${widget.grid.name}, '
                '${members.length} '
                '${plural(members.length, 'person', 'people')} on it',
      child: Tooltip(
        message: members == null
            ? 'Invite people to ${widget.grid.name}'
            : '${members.length} '
                  '${plural(members.length, 'person', 'people')} '
                  'on ${widget.grid.name}',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => ShareGridDialog.show(context, widget.grid),
            child: AnimatedContainer(
              duration: AppMotion.hover,
              curve: AppMotion.curve,
              height: GridCtaPair._halfHeight,
              padding: EdgeInsets.symmetric(
                horizontal: widget.showLabel ? 11 : 8,
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                // `accent`, never `accentOnSurface` — this is a fill under white
                // text, which is the one job that token is not for. White on it
                // measures 5.52:1.
                color: _hovered ? AppPalette.accentHover : AppPalette.accent,
                // The same lift its neighbour takes. A saturated chip separates
                // from the track on colour alone (5.151:1 light), but the pair
                // has to sit on one plane or it reads as one button beside one
                // label again.
                boxShadow: AppGlass.cardShadow,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    LucideIcons.userPlus300,
                    size: 14,
                    color: Colors.white,
                  ),
                  if (widget.showLabel) ...[
                    const SizedBox(width: 6),
                    const Text(
                      'Invite members',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: AppFont.semibold,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
