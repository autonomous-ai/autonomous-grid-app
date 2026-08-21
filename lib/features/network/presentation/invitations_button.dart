import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/age_label.dart';
import '../../../infrastructure/api/models/grid_invitation.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/anchored_menu_position.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../../shared/widgets/toast.dart';
import '../logic/invitations_controller.dart';

const double _menuWidth = 340;
// The panel's ceiling: what `anchoredMenuPosition` places against a window edge,
// and what `maximumSize` caps the panel at. Past it the panel scrolls itself —
// `_MenuPanelState.build` puts its children in a `SingleChildScrollView`, which
// is why nothing here adds one.
const double _menuHeight = 320;

/// The bell beside search: grids somebody has invited you to and you have not
/// looked at yet.
///
/// It earns a place in the header rather than a row in the list because an
/// invitation is the one thing here that arrives on somebody else's schedule.
/// Everything else in the sidebar is somewhere you chose to go.
///
/// **Always drawn; only the badge comes and goes.** It hid itself at zero at
/// first, on the argument that a bell which is almost always empty teaches
/// people to ignore it. That argument is about the badge, not the button: a
/// control that vanishes cannot be checked, so "did anyone invite me?" had no
/// answer on the ordinary day, and the header silently changed shape whenever
/// one arrived. The badge already carries the news; the bell is just where you
/// go to look.
class InvitationsButton extends ConsumerStatefulWidget {
  const InvitationsButton({super.key});

  @override
  ConsumerState<InvitationsButton> createState() => _InvitationsButtonState();
}

class _InvitationsButtonState extends ConsumerState<InvitationsButton> {
  final _menu = MenuController();

  void _toggle() {
    if (_menu.isOpen) {
      _menu.close();
      return;
    }
    // Opening is also a good moment to refetch: the poll is a minute wide, so
    // without this the list can be up to that stale at the instant somebody
    // deliberately went looking at it.
    ref.read(invitationsControllerProvider.notifier).refresh();
    _menu.open(
      position: anchoredMenuPosition(
        context,
        menuSize: const Size(_menuWidth, _menuHeight),
        alignEnd: true,
        maxHeight: _menuHeight,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final state = ref.watch(invitationsControllerProvider);
    final count = state.unseenCount;

    return MenuAnchor(
      controller: _menu,
      style: appMenuStyle().copyWith(
        minimumSize: const WidgetStatePropertyAll(Size(_menuWidth, 0)),
        maximumSize: const WidgetStatePropertyAll(
          Size(_menuWidth, _menuHeight),
        ),
      ),
      menuChildren: [
        _InvitationsMenu(
          items: state is InvitationsReady ? state.items : const [],
          onDone: _menu.close,
        ),
      ],
      builder: (context, controller, child) => IconButton(
        tooltip: switch (count) {
          0 => 'Invitations',
          1 => '1 new grid invitation',
          _ => '$count new grid invitations',
        },
        iconSize: 20,
        visualDensity: VisualDensity.compact,
        color: AppPalette.textSecondary,
        icon: _BellWithCount(count: count),
        onPressed: _toggle,
      ),
    );
  }
}

/// The bell with the count riding its corner.
///
/// A number rather than a bare dot: "you have something" and "you have four
/// things" are different pieces of news, and the second one is free to show.
class _BellWithCount extends StatelessWidget {
  const _BellWithCount({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    if (count == 0) return const Icon(LucideIcons.bell300);
    return Stack(
      // The badge overhangs the icon's box, which `Stack` clips by default.
      clipBehavior: Clip.none,
      children: [
        const Icon(LucideIcons.bell300),
        Positioned(
          right: -5,
          top: -3,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            constraints: const BoxConstraints(minWidth: 15),
            decoration: BoxDecoration(
              color: AppPalette.accent,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(
              // Past nine the exact number stops being useful and starts
              // widening a badge that has to sit on a 20px icon.
              count > 9 ? '9+' : '$count',
              textAlign: TextAlign.center,
              style: const TextStyle(
                // White on the accent in both themes — the accent is chosen to
                // carry white text, and flipping with the theme would put grey
                // on indigo in one of them.
                color: Colors.white,
                fontSize: 9,
                height: 1.3,
                fontWeight: AppFont.semibold,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _InvitationsMenu extends ConsumerWidget {
  const _InvitationsMenu({required this.items, required this.onDone});

  final List<GridInvitation> items;
  final VoidCallback onDone;

  Future<void> _mark(
    BuildContext context,
    WidgetRef ref,
    List<String> ids, {
    required bool closeAfter,
  }) async {
    final error = await ref
        .read(invitationsControllerProvider.notifier)
        .markSeen(ids);
    if (!context.mounted) return;
    if (error != null) {
      ToastScope.show(
        context,
        ToastSpec(message: error, severity: ToastSeverity.error),
      );
      return;
    }
    if (closeAfter) onDone();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    return SizedBox(
      width: _menuWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Invitations',
                    style: TextStyle(
                      color: AppPalette.textPrimary,
                      fontSize: 13,
                      fontWeight: AppFont.semibold,
                    ),
                  ),
                ),
                if (items.isNotEmpty)
                  TextButton(
                    onPressed: () => _mark(
                      context,
                      ref,
                      // The ids on screen, not "everything": one that arrives
                      // between the last poll and this tap is not in this list,
                      // so it survives rather than being dismissed unseen.
                      [for (final item in items) item.networkId],
                      closeAfter: true,
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: AppPalette.textSecondary,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: const Text(
                      'Mark all read',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
          if (items.isEmpty)
            // Says what it would hold rather than "Nothing here". Somebody who
            // opened this is asking a question, and "nothing" answers it only
            // if they already knew what the bell was for.
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Text(
                'Nobody has invited you to a grid since you last looked. '
                'Invitations show up here when they do.',
                style: TextStyle(
                  color: AppPalette.textSecondary,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            )
          else
          // ⚠️ **No scroller and no `ListView` here — the menu panel is
          // already one, and it cannot host either.** Verified in the SDK
          // (`material/menu_anchor.dart`, `_MenuPanelState.build`): a vertical
          // panel wraps its children in `IntrinsicWidth` and puts them in its
          // own `SingleChildScrollView`.
          //
          // `IntrinsicWidth` asks every child how wide it naturally is, and a
          // `ListView` is a viewport that cannot answer — which is why the
          // failure reads `RenderBox was not laid out` followed by a storm of
          // `!_debugDuringDeviceUpdate` from the mouse tracker, neither of
          // which names a list or this file. A `Flexible` fails the same way
          // for the neighbouring reason: the panel measures with unbounded
          // height and nothing can flex against infinity.
          //
          // So the rows go in plain, and overflow is the panel's own scroll
          // against `maximumSize`. This is the exception §4's "long lists
          // lazily" rule allows: the list is what one person has been invited
          // to since they last looked — single digits — and building it eagerly
          // is the only shape a menu accepts.
          ...[
            for (final item in items)
              _InvitationRow(
                invitation: item,
                now: now,
                onMarkRead: () => _mark(
                  context,
                  ref,
                  [item.networkId],
                  // Only the last one closes the menu; dismissing one of four
                  // should leave the other three where they are.
                  closeAfter: items.length == 1,
                ),
              ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

/// One invitation: which grid, who added you, what you may do, how long ago.
class _InvitationRow extends StatelessWidget {
  const _InvitationRow({
    required this.invitation,
    required this.now,
    required this.onMarkRead,
  });

  final GridInvitation invitation;
  final DateTime now;
  final VoidCallback onMarkRead;

  @override
  Widget build(BuildContext context) {
    final when = ageLabel(
      DateTime.fromMillisecondsSinceEpoch(invitation.addedAt * 1000),
      now,
    );
    final role = invitation.role;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  invitation.name.isEmpty
                      ? invitation.networkId
                      : invitation.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppPalette.textPrimary,
                    fontSize: 13,
                    fontWeight: AppFont.medium,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  // Names the person, because that is what makes an invitation
                  // legible — "somebody added you to a grid" is a notification
                  // nobody can act on.
                  '${invitation.addedBy} · $when ago',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppPalette.textSecondary,
                    fontSize: 11.5,
                    height: 1.3,
                  ),
                ),
                if (role != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    role.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppPalette.textSecondary,
                      fontSize: 11.5,
                      height: 1.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: 'Mark as read',
            iconSize: 15,
            visualDensity: VisualDensity.compact,
            color: AppPalette.textSecondary,
            icon: const Icon(LucideIcons.check300),
            onPressed: onMarkRead,
          ),
        ],
      ),
    );
  }
}
