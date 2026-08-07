import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/labeled_field.dart';
import '../../logic/commit_controller.dart';
import '../../logic/review_controller.dart';
import '../../logic/review_snapshot.dart';
import 'commit_sheet.dart';
import 'menu_row.dart';
import 'review_feedback.dart';

/// "Commit or push" — the toolbar's one bright control.
///
/// Two halves of one button, the way Codex draws it: the label does the thing
/// you almost always want (open the commit box), and the caret offers the two
/// you sometimes do — push what is already committed, or tick everything first.
class CommitButton extends ConsumerStatefulWidget {
  const CommitButton({super.key, required this.snapshot, required this.folder});

  final ReviewSnapshot snapshot;
  final String folder;

  static const double menuWidth = 250;

  @override
  ConsumerState<CommitButton> createState() => _CommitButtonState();
}

class _CommitButtonState extends ConsumerState<CommitButton> {
  final _menu = MenuController();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final snapshot = widget.snapshot;
    final staged = snapshot.staged.length;
    final ahead = snapshot.ahead;
    final running = ref.watch(commitProvider(widget.folder)) is CommitRunning;

    // Nothing to commit and nothing to push: the button would promise an
    // action the repository can't perform.
    if (snapshot.isEmpty && ahead == 0) return const SizedBox.shrink();

    return MenuAnchor(
      controller: _menu,
      alignmentOffset: const Offset(0, 6),
      style: appMenuStyle(),
      menuChildren: [
        MenuRow(
          label: 'Include every change',
          detail: staged == snapshot.files.length
              ? 'Everything is ticked already'
              : 'Tick all ${snapshot.files.length} files, then commit',
          icon: LucideIcons.listChecks,
          width: CommitButton.menuWidth,
          enabled: staged != snapshot.files.length,
          onTap: _includeAll,
        ),
        MenuRow(
          label: 'Push what is committed',
          detail: ahead == 0
              ? 'Nothing is waiting to be pushed'
              : '$ahead commit${ahead == 1 ? '' : 's'} on this computer only',
          icon: LucideIcons.arrowUp,
          width: CommitButton.menuWidth,
          enabled: ahead > 0 && !snapshot.detached,
          onTap: _pushOnly,
        ),
      ],
      builder: (context, controller, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton(
            style: FilledButton.styleFrom(
              // Square the inner edge so the two halves read as one control.
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.horizontal(
                  left: Radius.circular(AppControl.radius),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            onPressed: running || staged == 0
                ? null
                : () => showCommitSheet(context, folder: widget.folder),
            child: Text(staged == 0 ? 'Nothing ticked' : 'Commit'),
          ),
          const SizedBox(width: 1),
          FilledButton(
            style: FilledButton.styleFrom(
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.horizontal(
                  right: Radius.circular(AppControl.radius),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 0),
            ),
            onPressed: running
                ? null
                : () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
            child: AnimatedRotation(
              duration: AppMotion.hover,
              curve: AppMotion.curve,
              turns: controller.isOpen ? 0.5 : 0,
              child: const Icon(LucideIcons.chevronDown, size: 13),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _includeAll() async {
    _menu.close();
    final failure = await ref
        .read(reviewProvider(widget.folder).notifier)
        .stageAll();
    if (failure == null || !mounted) return;
    showReviewFailure(context, failure);
  }

  Future<void> _pushOnly() async {
    _menu.close();
    await ref.read(commitProvider(widget.folder).notifier).pushOnly();
    if (!mounted) return;
    final state = ref.read(commitProvider(widget.folder));
    if (state is CommitFailed) showReviewFailure(context, state.message);
  }
}
