import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../logic/commit_action.dart';
import '../../logic/review_comment.dart';
import '../../logic/review_comments_controller.dart';
import '../../logic/review_controller.dart';
import '../../logic/review_scope.dart';
import '../../logic/review_snapshot.dart';
import 'commit_button.dart';
import 'review_mark.dart';
import 'scope_menu.dart';
import 'toolbar_pill.dart';

/// The row under the panel's tabs: which changes are on screen, how much they
/// come to, and what can be done with them.
///
/// One row, in the order Codex puts it — what you are looking at on the left,
/// what you can do on the right. Which *branch* those changes are on is not
/// here but over the file list: it belongs to the change set, not to the
/// controls, and the toolbar's height is fixed by `PanelBody` so every tab's
/// seam sits on the same line.
///
/// No close button: the tab holding this surface carries its own, and two ✕s
/// for one thing is the duplication the panel was built to avoid.
class ReviewToolbar extends ConsumerStatefulWidget {
  const ReviewToolbar({
    super.key,
    required this.snapshot,
    required this.folder,
    required this.onAskAgent,
  });

  final ReviewSnapshot snapshot;
  final String folder;

  /// Hands a message to whatever hosts this surface, to put in the composer.
  final ValueChanged<String> onAskAgent;

  @override
  ConsumerState<ReviewToolbar> createState() => _ReviewToolbarState();
}

class _ReviewToolbarState extends ConsumerState<ReviewToolbar> {
  bool _refreshing = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final snapshot = widget.snapshot;
    final comments = ref.watch(reviewCommentsProvider(widget.folder));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          // One flexible child, not two. With a `Flexible` scope menu *and* a
          // `Spacer`, the row split the free space between them, the loose
          // scope menu gave most of its half back — and the space it returned
          // stayed where it was, stranding the actions in the middle of the
          // toolbar instead of at its right edge.
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: ScopeMenu(snapshot: snapshot, folder: widget.folder),
                ),
                const SizedBox(width: 8),
                ChangeCount(added: snapshot.added, removed: snapshot.removed),
              ],
            ),
          ),
          // Comments outrank "review this": the user has already read the diff
          // and said what they want, and the button that would throw that away
          // must not look like the one that sends it.
          if (comments.isNotEmpty)
            ToolbarPill(
              onTap: _sendComments,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    LucideIcons.messageSquare,
                    size: 13,
                    color: AppPalette.accentOnSurface,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Send ${comments.length} comment'
                    '${comments.length == 1 ? '' : 's'}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: AppFont.medium,
                      color: AppPalette.accentOnSurface,
                    ),
                  ),
                ],
              ),
            )
          else if (!snapshot.isEmpty)
            AppIconButton(
              icon: LucideIcons.sparkles,
              size: 15,
              tooltip: 'Ask the assistant to review these changes',
              onPressed: () =>
                  widget.onAskAgent(askAgentPrompt(snapshot.scope)),
            ),
          // Sized so the spinner and the glyph occupy the same square: a
          // toolbar that reflows every time you refresh reads as a jolt.
          SizedBox(
            width: 26,
            height: 26,
            child: Center(
              child: _refreshing
                  ? const AppSpinner(size: SpinnerSize.small)
                  : AppIconButton(
                      icon: LucideIcons.refreshCw,
                      size: 15,
                      tooltip: 'Look again',
                      onPressed: _refresh,
                    ),
            ),
          ),
          // Asked of the same function the button itself uses, so the gap in
          // front of it can't outlive the control — and so a scope that can't
          // stage still shows it when there are commits waiting to be pushed.
          if (commitActionFor(snapshot) != CommitAction.none) ...[
            const SizedBox(width: 6),
            CommitButton(snapshot: snapshot, folder: widget.folder),
          ],
        ],
      ),
    );
  }

  /// Hand every remark to the assistant, then let them go: they were a request
  /// in the making, and one that has been sent must not be sent again with the
  /// next question.
  void _sendComments() {
    widget.onAskAgent(
      commentsPrompt(ref.read(reviewCommentsProvider(widget.folder))),
    );
    ref.read(reviewCommentsProvider(widget.folder).notifier).clear();
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    await ref.read(reviewProvider(widget.folder).notifier).refresh();
    if (mounted) setState(() => _refreshing = false);
  }
}

/// Which branch these changes are on, how it stands against its remote, and how
/// much of it is ticked for the next commit.
///
/// Over the file list rather than in the toolbar: it says what the list *is*,
/// and the toolbar's fixed height has no room for a second line.
class ReviewBranchLine extends StatelessWidget {
  const ReviewBranchLine({super.key, required this.snapshot});

  final ReviewSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // A detached HEAD is the one state worth interrupting for: a commit made
    // there belongs to no branch, and the next checkout leaves it unreachable.
    if (snapshot.detached) {
      return _Line(
        icon: LucideIcons.triangleAlert,
        text: 'Not on a branch — a commit made here would belong to none.',
        tint: Theme.of(context).colorScheme.error,
      );
    }
    final staged = snapshot.staged.length;
    final distance = [
      if (snapshot.ahead > 0) '${snapshot.ahead} to push',
      if (snapshot.behind > 0) '${snapshot.behind} to pull',
      if (staged > 0 && snapshot.scope.canStage) '$staged ticked',
    ].join(' · ');

    return _Line(
      icon: LucideIcons.gitBranch,
      text: distance.isEmpty
          ? snapshot.branch
          : '${snapshot.branch} · $distance',
    );
  }
}

/// One quiet line of status.
class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.text, this.tint});

  final IconData icon;
  final String text;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final colour = tint ?? AppPalette.textSecondary;
    return Row(
      children: [
        Icon(icon, size: 13, color: colour),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, color: colour),
          ),
        ),
      ],
    );
  }
}
