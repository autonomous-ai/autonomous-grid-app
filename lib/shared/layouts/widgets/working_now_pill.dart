import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/chat/logic/chat_sessions_controller.dart';
import '../../../features/chat/logic/working_chats.dart';
import '../../../features/network/logic/grid_power_provider.dart' show plural;
import '../../theme/app_theme.dart';
import '../../widgets/app_spinner.dart';
import '../shell_state.dart';
import 'pill_panel_shell.dart';
import 'top_bar_pill.dart';
import 'working_now_panel.dart';

/// How many chats are answering right now, wherever they are — and the way into
/// any of them.
///
/// The app can run a turn in several chats at once, in projects the user isn't
/// looking at. Until this, the only sign of one was a spinner on its sidebar row
/// — invisible under a collapsed project, on another screen, or in Code. The
/// pill is the app's one app-wide answer to "what is still going?", and the
/// panel behind it is where each of those turns can be reached or stopped.
///
/// Unmounted while nothing is running, like the download pill beside it: the bar
/// is otherwise empty, and a capsule reading "0" would be furniture.
class WorkingNowPill extends ConsumerStatefulWidget {
  const WorkingNowPill({super.key});

  @override
  ConsumerState<WorkingNowPill> createState() => _WorkingNowPillState();
}

class _WorkingNowPillState extends ConsumerState<WorkingNowPill> {
  final _link = LayerLink();
  final _controller = OverlayPortalController();

  /// Ties the pill and its panel into one tap region, so a click inside the
  /// panel isn't the "click outside" that closes it — the panel is drawn in an
  /// overlay, outside the pill's own subtree.
  final _tapGroup = Object();

  /// Whether the panel is open. Click to open, click again (or anywhere outside)
  /// to close — deliberately not hover, unlike the grid pill: every row here
  /// carries actions, and reaching a Stop button means crossing the gap between
  /// pill and panel, which a hover-held popover would close on the way.
  bool _open = false;

  void _toggle() {
    if (_open) {
      _close();
      return;
    }
    setState(() => _open = true);
    _controller.show();
  }

  /// Guarded on [OverlayPortalController.isShowing]: the pill unmounts as soon
  /// as it is closed with nothing running, and hiding a controller whose portal
  /// has gone asserts.
  void _close() {
    if (_controller.isShowing) _controller.hide();
    if (mounted) setState(() => _open = false);
  }

  /// Go to the chat this row is about. The panel closes first — a popover left
  /// hanging over the transcript it just opened is in the way of the very thing
  /// the user asked to see.
  void _openChat(String id) {
    _close();
    ref.read(chatSessionsProvider.notifier).select(id);
    ref.read(shellSectionProvider.notifier).select(ShellSection.chat);
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // The count alone, so a streaming token never rebuilds the top bar: the rows
    // themselves are watched by the panel, and only while it is open.
    final count = ref.watch(workingChatsProvider.select((w) => w.length));
    // Nothing running and nothing open: leave the bar clean. Still drawn while
    // the panel is open, so the last turn landing doesn't yank the panel out
    // from under whoever is reading it — see [WorkingNowPanel].
    if (count == 0 && !_open) return const SizedBox.shrink();

    final label = count == 0
        ? 'Nothing working'
        : '$count ${plural(count, 'chat')} working';
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: TapRegion(
        groupId: _tapGroup,
        onTapOutside: (_) {
          if (_open) _close();
        },
        child: CompositedTransformTarget(
          link: _link,
          child: OverlayPortal(
            controller: _controller,
            overlayChildBuilder: (context) => _Panel(
              link: _link,
              tapGroupId: _tapGroup,
              onOpenChat: _openChat,
            ),
            child: Semantics(
              label: label,
              button: true,
              container: true,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggle,
                  child: Tooltip(
                    message: count == 0
                        ? 'Nothing is working right now'
                        : 'See what is working',
                    child: TopBarPill(child: _PillRow(label: label)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The capsule's contents: a spinner and the count.
///
/// A spinner rather than a dot, matching the download pill: both report work in
/// progress, and the top bar should say that one way.
class _PillRow extends StatelessWidget {
  const _PillRow({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const AppSpinner(size: SpinnerSize.small),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: AppFont.medium,
            color: AppPalette.textSecondary,
          ),
        ),
      ],
    );
  }
}

/// The panel, hung from the pill's right edge so it grows leftwards into the
/// window rather than off it — the pill sits at the right end of the top bar,
/// where a left-anchored popover would run past the frame.
class _Panel extends StatelessWidget {
  const _Panel({
    required this.link,
    required this.tapGroupId,
    required this.onOpenChat,
  });

  final LayerLink link;
  final Object tapGroupId;
  final ValueChanged<String> onOpenChat;

  /// Wide enough for a chat's name over a line naming its project, its agent and
  /// the step it is on — the widest of the top bar's popovers, and still narrow
  /// enough to read as one column.
  static const double _width = 320;

  /// The surface's own padding, undone so its text lines up with the pill's
  /// rather than being inset from it by a rim's width.
  static const double _inset = 13;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      width: _width,
      child: CompositedTransformFollower(
        link: link,
        targetAnchor: Alignment.bottomRight,
        followerAnchor: Alignment.topRight,
        offset: const Offset(_inset, 8),
        child: TapRegion(
          groupId: tapGroupId,
          child: PillPanelSurface(
            child: WorkingNowPanel(onOpenChat: onOpenChat),
          ),
        ),
      ),
    );
  }
}
