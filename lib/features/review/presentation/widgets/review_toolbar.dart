import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../logic/review_controller.dart';
import '../../logic/review_scope.dart';
import '../../logic/review_snapshot.dart';
import 'commit_button.dart';
import 'review_mark.dart';
import 'scope_menu.dart';

/// The top of the Review surface: which changes are on screen, how much they
/// come to, and the three things you can do with them.
///
/// One row of controls and one quiet line about the branch, in the order Codex
/// puts them: what you are looking at on the left, what you can do on the
/// right.
class ReviewToolbar extends ConsumerStatefulWidget {
  const ReviewToolbar({
    super.key,
    required this.snapshot,
    required this.folder,
    required this.onClose,
    required this.onAskAgent,
  });

  final ReviewSnapshot snapshot;
  final String folder;

  /// Leaves Review and puts the panel back to what it can open.
  final VoidCallback onClose;

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
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Flexible(
                child: ScopeMenu(snapshot: snapshot, folder: widget.folder),
              ),
              const SizedBox(width: 8),
              ChangeCount(added: snapshot.added, removed: snapshot.removed),
              const Spacer(),
              if (!snapshot.isEmpty)
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
              AppIconButton(
                icon: LucideIcons.x,
                size: 15,
                tooltip: 'Close Review',
                onPressed: widget.onClose,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: _Branch(snapshot: snapshot)),
              const SizedBox(width: 8),
              // Also when the scope can't stage: a branch with commits waiting
              // still has something to push, and hiding the control there would
              // send the user looking for another screen.
              if (snapshot.scope.canStage || snapshot.ahead > 0)
                CommitButton(snapshot: snapshot, folder: widget.folder),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    await ref.read(reviewProvider(widget.folder).notifier).refresh();
    if (mounted) setState(() => _refreshing = false);
  }
}

/// Which branch this is, how it stands against its remote, and what is ticked.
class _Branch extends ConsumerWidget {
  const _Branch({required this.snapshot});

  final ReviewSnapshot snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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

/// One quiet line of status under the controls.
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
