import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../logic/commit_action.dart';
import '../../logic/commit_controller.dart';
import '../../logic/review_snapshot.dart';
import 'commit_popover.dart';
import 'toolbar_pill.dart';
import 'toolbar_popover.dart';

/// The toolbar's one tinted control, and the panel it opens.
///
/// One pill rather than a split button: everything it could do — commit, commit
/// and push, push, sweep in the files that aren't ticked — lives in the panel
/// under it, where the message is typed. A button that both did something on
/// click *and* hid two more actions behind a caret made the user guess which
/// half they were pressing.
class CommitButton extends ConsumerWidget {
  const CommitButton({super.key, required this.snapshot, required this.folder});

  final ReviewSnapshot snapshot;
  final String folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final action = commitActionFor(snapshot);
    // Nothing to commit and nothing to push: a control here would name an
    // action the repository can't perform.
    if (action == CommitAction.none) return const SizedBox.shrink();

    final running = ref.watch(commitProvider(folder)) is CommitRunning;
    final ink = ToolbarPill.tint(tinted: true, enabled: true);

    return ToolbarPopover(
      width: CommitPopover.width,
      // The panel is the only place a commit's outcome is reported, so it stays
      // put while one is in flight.
      dismissible: !running,
      panel: (context, close) =>
          CommitPopover(snapshot: snapshot, folder: folder, onClose: close),
      trigger: (context, open, toggle) => ToolbarPill(
        tinted: true,
        active: open,
        onTap: toggle,
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
    );
  }
}
