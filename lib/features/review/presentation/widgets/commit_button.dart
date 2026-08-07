import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../logic/commit_action.dart';
import '../../logic/commit_controller.dart';
import '../../logic/review_snapshot.dart';
import 'commit_popover.dart';
import 'toolbar_pill.dart';

/// The toolbar's one tinted control, and the panel it opens.
///
/// One pill rather than a split button: everything it could do — commit, commit
/// and push, push, sweep in the files that aren't ticked — lives in the panel
/// under it, where the message is typed. A button that both did something on
/// click *and* hid two more actions behind a caret made the user guess which
/// half they were pressing.
class CommitButton extends ConsumerStatefulWidget {
  const CommitButton({super.key, required this.snapshot, required this.folder});

  final ReviewSnapshot snapshot;
  final String folder;

  @override
  ConsumerState<CommitButton> createState() => _CommitButtonState();
}

class _CommitButtonState extends ConsumerState<CommitButton> {
  final _link = LayerLink();
  final _panel = OverlayPortalController();

  /// Ties the pill and its panel into one region, so a click on either is
  /// "inside" and only a click elsewhere dismisses.
  final _group = Object();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final action = commitActionFor(widget.snapshot);
    // Nothing to commit and nothing to push: a control here would name an
    // action the repository can't perform.
    if (action == CommitAction.none) return const SizedBox.shrink();

    final running = ref.watch(commitProvider(widget.folder)) is CommitRunning;
    final open = _panel.isShowing;
    final ink = ToolbarPill.tint(tinted: true, enabled: true);

    return TapRegion(
      groupId: _group,
      onTapOutside: (_) {
        // Never while a commit or a push is in flight: the panel is the only
        // place the outcome is reported, and a stray click behind it would
        // take that away mid-run.
        if (open && !running) _close();
      },
      child: CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _panel,
          overlayChildBuilder: (context) => _Panel(
            link: _link,
            group: _group,
            snapshot: widget.snapshot,
            folder: widget.folder,
            onClose: _close,
          ),
          child: ToolbarPill(
            tinted: true,
            active: open,
            onTap: () => setState(() => open ? _panel.hide() : _panel.show()),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.gitCommitHorizontal, size: 13, color: ink),
                const SizedBox(width: 6),
                Text(
                  action.panelLabel,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: AppFont.medium,
                    color: ink,
                  ),
                ),
                const SizedBox(width: 4),
                AnimatedRotation(
                  duration: AppMotion.hover,
                  curve: AppMotion.curve,
                  turns: open ? 0.5 : 0,
                  child: Icon(LucideIcons.chevronDown, size: 13, color: ink),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _close() => setState(_panel.hide);
}

/// The panel, hung under the pill's right edge.
///
/// Right-aligned because the pill is: a panel that opened leftwards from a
/// control at the end of the toolbar would run off the panel's own edge.
class _Panel extends StatelessWidget {
  const _Panel({
    required this.link,
    required this.group,
    required this.snapshot,
    required this.folder,
    required this.onClose,
  });

  final LayerLink link;
  final Object group;
  final ReviewSnapshot snapshot;
  final String folder;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Positioned(
    width: CommitPopover.width,
    child: CompositedTransformFollower(
      link: link,
      targetAnchor: Alignment.bottomRight,
      followerAnchor: Alignment.topRight,
      offset: const Offset(0, 6),
      child: TapRegion(
        groupId: group,
        child: CommitPanelSurface(
          child: CommitPopover(
            snapshot: snapshot,
            folder: folder,
            onClose: onClose,
          ),
        ),
      ),
    ),
  );
}
