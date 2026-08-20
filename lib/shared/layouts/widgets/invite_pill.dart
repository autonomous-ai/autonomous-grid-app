import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../features/auth/logic/session_controller.dart';
import '../../../features/network/logic/grid_power_provider.dart' show plural;
import '../../../features/network/logic/member_display.dart'
    show memberAvatarSlots;
import '../../../features/network/logic/member_providers.dart';
import '../../../features/network/logic/member_usage_provider.dart';
import '../../../features/network/presentation/share_grid_dialog.dart';
import '../../../infrastructure/api/models/managed_network_member.dart';
import '../../theme/app_theme.dart';
import '../../widgets/member_avatar.dart';

/// Who is on the grid, and the way to add someone — at the right of the top
/// bar, beside the grid the invite would be *to*.
///
/// Bringing a colleague onto a grid used to be three clicks deep in the account
/// menu, filed between Settings and Sign out — with the things you do to the
/// *app* rather than the things you do to the *grid*. Nobody found it, and the
/// members panel two hundred pixels away could name all thirty-three people
/// without offering a way to add a thirty-fourth.
///
/// Faces before the button on purpose. The stack is what says *which* grid this
/// invites to, and it makes the button's word concrete before it is read — the
/// same reason a share sheet shows avatars rather than a count. It is also the
/// only thing on this bar that is about people rather than about hardware.
///
/// One control, not two. The faces and the button both open [ShareGridDialog],
/// which is the screen that answers both questions the cluster raises — who is
/// here, and how do I add someone — so splitting it into two targets would be
/// two doors into one room.
class InvitePill extends ConsumerStatefulWidget {
  const InvitePill({super.key});

  /// How many faces the stack shows before the rest become a count.
  ///
  /// Four, because the fifth is where the stack stops reading as *people* and
  /// starts reading as a texture — and because the overflow chip has to earn
  /// its place: with five members a "+1" chip costs the same width as the face
  /// it replaces and says less.
  static const int _maxFaces = 4;

  /// Below this the faces go and the button stands alone.
  ///
  /// The window's width, not the bar's: a `LayoutBuilder` here would be no help
  /// because a `Row` measures its non-flex children against *unbounded* width
  /// before handing what is left to the `Expanded` header, so this pill can
  /// never be told how much room it actually has.
  ///
  /// The numbers come from what the bar already carries. On a busy grid the
  /// pills to the right of the header run ~830px before this one is added —
  /// the grid capsule alone is ~555 — against a bar that is the window less the
  /// 274px rail. At 1400 the stack's ~110px still leaves the conversation's
  /// title something to be; below it, the faces are the half that can go
  /// without losing the action.
  static const double _facesFrom = 1400;

  /// Below this the label goes too, leaving the glyph — ~39px in all, which is
  /// what this feature costs a window too narrow for anything else. An
  /// icon-only button is a worse button, but a button whose label is cut in
  /// half is not a button at all, and dropping the pill entirely would take the
  /// action away from exactly the people whose screen gives them the least
  /// room to go hunting for it.
  static const double _labelFrom = 1180;

  @override
  ConsumerState<InvitePill> createState() => _InvitePillState();
}

class _InvitePillState extends ConsumerState<InvitePill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // Const-mounted by [AppTopBar], so the bar's own rebuild stops short of
    // here: without this the button keeps whichever accent it first painted.
    AppTheme.watch(context);
    final grid = ref.watch(selectedNetworkProvider);
    // No grid in scope, nothing to invite anyone to. Unmounted rather than
    // disabled, like every other pill on this bar.
    if (grid == null) return const SizedBox.shrink();

    // Read for the faces only, never to gate the button: the roster comes from
    // the control plane and can be slow or unreadable, and an invite that
    // waits for a list it does not need would be missing exactly when a new
    // grid has nobody on it yet.
    final members = ref.watch(networkMembersProvider(grid.networkId)).value;
    // The same order the members panel lists them in, so the four faces here
    // are the four rows at the top of the panel the pill opens. Degrades to the
    // roster's own order when the relay reports no usage — `sortMembersByUsage`
    // handles the null map.
    final ranked = members == null
        ? const <ManagedNetworkMember>[]
        : sortMembersByUsage(
            members,
            ref.watch(gridMemberUsageProvider).value?.byEmail,
            emailOf: (m) => m.email,
          );

    final width = MediaQuery.sizeOf(context).width;
    final showFaces = ranked.isNotEmpty && width >= InvitePill._facesFrom;
    final showLabel = width >= InvitePill._labelFrom;

    // The gap goes on the *right*, and outside the gesture detector.
    //
    // Every other pill on this bar pads its own right edge by 8, so a pill's
    // left gap is its neighbour's padding. Padding on the left instead — which
    // is what this did — put 16px before the cluster and **nothing** after it:
    // the button's solid edge ended up flush against the grid capsule, with
    // only that capsule's inner padding keeping its status dot off the label.
    //
    // 12 rather than the bar's 8 because this is the one opaque surface in a
    // row of translucent ones, and a saturated block sitting 8px off a glass
    // capsule still reads as attached to it.
    //
    // Outside the detector so the gap is page, not target: inside, a click 10px
    // to the left of the grid pill would open the invite dialog.
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Semantics(
        button: true,
        label: members == null
            ? 'Invite people to ${grid.name}'
            : 'Invite people to ${grid.name}, '
                  '${members.length} '
                  '${plural(members.length, 'person', 'people')} on it',
        child: Tooltip(
          message: members == null
              ? 'Invite people to ${grid.name}'
              : '${members.length} '
                    '${plural(members.length, 'person', 'people')} '
                    'on ${grid.name}',
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => ShareGridDialog.show(context, grid),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showFaces) ...[
                    _FaceStack(members: ranked),
                    const SizedBox(width: 9),
                  ],
                  _InviteButton(hovered: _hovered, showLabel: showLabel),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The first few members as overlapping circles, and a count for the rest.
///
/// The overlap is what makes this a *group* rather than a row of marks, and the
/// ring cut around each disc is what keeps the one behind from bleeding into
/// the one in front. That ring is [AppPalette.windowBg] because the top bar has
/// no fill of its own — it is seamless with the pane below it — so the page is
/// literally what shows through the gap.
class _FaceStack extends StatelessWidget {
  const _FaceStack({required this.members});

  final List<ManagedNetworkMember> members;

  /// The disc itself, before the ring. 22 matches the members panel's rows, so
  /// a face is the same size in the stack and in the list the stack opens.
  static const double _face = 22;

  /// How far each disc slides under the one before it. A third of the face:
  /// enough to read as a stack, little enough to leave every letter whole.
  static const double _overlap = 8;

  /// What one disc occupies once its ring is counted, and how far the next one
  /// starts along from it. Derived rather than typed twice — the stack's width
  /// is built from these, and a step that disagreed with the ring would leave
  /// a hairline of page between two faces that are meant to touch.
  static const double _disc = _face + MemberAvatar.ringWidth * 2;
  static const double _step = _disc - _overlap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final shown = members.take(InvitePill._maxFaces).toList(growable: false);
    final rest = members.length - shown.length;
    // Over the whole ranked roster, not just the four faces drawn: the panel
    // this stack opens colours the same list the same way, so a face here and
    // the row it stands for down there are one colour.
    final slots = memberAvatarSlots([
      for (final member in members) member.email,
    ], AppPalette.avatarPalette.length);
    final discs = <Widget>[
      for (final (i, member) in shown.indexed)
        MemberAvatar(
          email: member.email,
          slot: slots[i],
          size: _face,
          fontSize: 10.5,
          ring: AppPalette.windowBg,
        ),
      if (rest > 0) _OverflowCount(rest: rest),
    ];
    // A `Stack`, not a `Row` of negative paddings: `Padding` asserts its insets
    // are non-negative, so the obvious spelling of an overlap throws in debug
    // and silently mislays the stack in release. Laying the discs out by hand
    // also means the box measures exactly what is drawn, which is what keeps
    // the button beside it from being pushed off the bar.
    //
    // Later discs paint over earlier ones, so the stack reads left-to-right as
    // a queue rather than as a fan.
    return SizedBox(
      width: _disc + (discs.length - 1) * _step,
      height: _disc,
      child: Stack(
        children: [
          for (final (i, disc) in discs.indexed)
            Positioned(left: i * _step, child: disc),
        ],
      ),
    );
  }
}

/// The people the stack had no room for, as "+29".
///
/// Deliberately not a ninth avatar colour: this is a number, not a person, and
/// giving it a face's fill would make it the one member of the grid nobody can
/// name. A recessed disc in the panel greys instead, with the same ring as its
/// neighbours so the stack keeps one silhouette.
class _OverflowCount extends StatelessWidget {
  const _OverflowCount({required this.rest});

  final int rest;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      width: _FaceStack._face + MemberAvatar.ringWidth * 2,
      height: _FaceStack._face + MemberAvatar.ringWidth * 2,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppPalette.windowBg,
      ),
      child: Container(
        width: _FaceStack._face,
        height: _FaceStack._face,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppPalette.cardBgHover,
        ),
        child: Text(
          '+$rest',
          style: TextStyle(
            fontSize: 9.5,
            fontWeight: FontWeight.w600,
            color: AppPalette.textSecondary,
            fontFeatures: AppFont.tabularFigures,
          ),
        ),
      ),
    );
  }
}

/// The filled half of the cluster.
///
/// The one solid accent surface in a bar that is otherwise all glass capsules,
/// which is the point: this is the only thing up here that asks to be pressed
/// rather than read. It keeps the bar's stadium shape so it reads as a member
/// of the same family — a radius-8 control among radius-999 pills would look
/// like it arrived from another screen.
class _InviteButton extends StatelessWidget {
  const _InviteButton({required this.hovered, required this.showLabel});

  final bool hovered;
  final bool showLabel;

  /// The height every other pill on this bar settles at (10 of padding around
  /// an 18px line), so the cluster sits on the same two edges as its
  /// neighbours.
  static const double _height = 28;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return AnimatedContainer(
      duration: AppMotion.hover,
      curve: AppMotion.curve,
      height: _height,
      padding: EdgeInsets.symmetric(horizontal: showLabel ? 11 : 8),
      decoration: BoxDecoration(
        // `accent`, which is the same value in both themes, and never
        // `accentOnSurface` — this is a fill under white text, which is the one
        // job that token is not for. White on it measures 5.52:1.
        color: hovered ? AppPalette.accentHover : AppPalette.accent,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(LucideIcons.userPlus300, size: 15, color: Colors.white),
          if (showLabel) ...[
            const SizedBox(width: 7),
            const Text(
              'Invite',
              style: TextStyle(
                fontSize: AppControl.fontSize,
                fontWeight: AppControl.fontWeight,
                color: Colors.white,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
