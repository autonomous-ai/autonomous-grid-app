import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/toast.dart';
import '../../logic/review_base.dart';
import '../../logic/review_controller.dart';
import '../../logic/review_snapshot.dart';
import 'base_picker.dart';
import 'commit_sheet.dart';
import 'review_mark.dart';

/// The top of the Review surface: which branch, measured against what, how much
/// changed — and the two things you can do about it.
class ReviewHeader extends ConsumerStatefulWidget {
  const ReviewHeader({
    super.key,
    required this.snapshot,
    required this.folder,
    required this.onClose,
    required this.onAskAgent,
  });

  final ReviewSnapshot snapshot;
  final String folder;

  /// Dismisses Review — see [ReviewSurface.onClose] for what the host does
  /// with that.
  final VoidCallback onClose;

  /// Hands a message to whatever hosts this surface, to put in the composer.
  final ValueChanged<String> onAskAgent;

  @override
  ConsumerState<ReviewHeader> createState() => _ReviewHeaderState();
}

class _ReviewHeaderState extends ConsumerState<ReviewHeader> {
  bool _refreshing = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final snapshot = widget.snapshot;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                LucideIcons.gitBranch,
                size: 14,
                color: AppPalette.textSecondary,
              ),
              const SizedBox(width: 6),
              Expanded(child: _Branch(snapshot: snapshot)),
              if (!snapshot.isEmpty)
                AppIconButton(
                  icon: LucideIcons.sparkles,
                  size: 15,
                  tooltip: 'Ask the assistant to review these changes',
                  onPressed: () =>
                      widget.onAskAgent(askAgentPrompt(snapshot.base)),
                ),
              // Sized so the spinner and the glyph occupy the same square: a
              // header that reflows every time you refresh reads as a jolt.
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
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: BasePicker(snapshot: snapshot, folder: widget.folder),
              ),
              const SizedBox(width: 8),
              ChangeCount(added: snapshot.added, removed: snapshot.removed),
            ],
          ),
          if (snapshot.base is UncommittedChanges) ...[
            const SizedBox(height: 8),
            _CommitBar(snapshot: snapshot, folder: widget.folder),
          ],
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

/// Which branch this is, and how it stands against its remote.
class _Branch extends StatelessWidget {
  const _Branch({required this.snapshot});

  final ReviewSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    // A detached HEAD is the one state worth interrupting for: a commit made
    // there belongs to no branch, and the next checkout leaves it unreachable.
    final detached = snapshot.detached;
    final distance = [
      if (snapshot.ahead > 0) '${snapshot.ahead} to push',
      if (snapshot.behind > 0) '${snapshot.behind} to pull',
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          detached ? 'Not on a branch' : snapshot.branch,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontWeight: AppFont.medium,
            color: detached
                ? Theme.of(context).colorScheme.error
                : AppPalette.textPrimary,
          ),
        ),
        if (detached)
          Text(
            'Commits made here belong to no branch — switch to one first.',
            style: TextStyle(fontSize: 11, color: AppPalette.textSecondary),
          )
        else if (distance.isNotEmpty)
          Text(
            distance,
            style: TextStyle(fontSize: 11, color: AppPalette.textSecondary),
          ),
      ],
    );
  }
}

/// What a commit would carry right now, and the button that makes it.
class _CommitBar extends ConsumerWidget {
  const _CommitBar({required this.snapshot, required this.folder});

  final ReviewSnapshot snapshot;
  final String folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    if (snapshot.isEmpty) return const SizedBox.shrink();

    final staged = snapshot.staged.length;
    return Row(
      children: [
        Expanded(
          child: Text(
            staged == 0
                ? 'Tick the files to include, then commit.'
                : '$staged of ${snapshot.files.length} ready to commit',
            maxLines: 2,
            style: TextStyle(fontSize: 11.5, color: AppPalette.textSecondary),
          ),
        ),
        const SizedBox(width: 8),
        if (staged == 0)
          TextButton(
            onPressed: () => _includeAll(context, ref),
            child: const Text('Include all'),
          )
        else
          FilledButton(
            onPressed: () => showCommitSheet(context, folder: folder),
            child: const Text('Commit…'),
          ),
      ],
    );
  }

  /// Stage everything. A refusal is shown rather than swallowed: the tick
  /// marks simply not appearing is indistinguishable from a button that does
  /// nothing.
  Future<void> _includeAll(BuildContext context, WidgetRef ref) async {
    final failure = await ref.read(reviewProvider(folder).notifier).stageAll();
    if (failure == null || !context.mounted) return;
    ToastScope.show(
      context,
      ToastSpec(message: failure, severity: ToastSeverity.error),
    );
  }
}
