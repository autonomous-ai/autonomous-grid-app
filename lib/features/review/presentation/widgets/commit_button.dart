import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/labeled_field.dart';
import '../../logic/commit_action.dart';
import '../../logic/commit_controller.dart';
import '../../logic/review_controller.dart';
import '../../logic/review_snapshot.dart';
import 'commit_sheet.dart';
import 'menu_row.dart';
import 'review_feedback.dart';

/// The toolbar's one bright control: commit these changes, or push them.
///
/// Two halves of one button, the way Codex draws it — the label does the thing
/// the repository is asking for ([commitActionFor]), and the caret holds
/// whichever of the others is still possible. When nothing else is, there is no
/// caret: half a control that opens an empty menu is worse than no menu.
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
    final action = commitActionFor(snapshot);
    // Nothing to commit and nothing to push: a button here would name an action
    // the repository can't perform.
    if (action == CommitAction.none) return const SizedBox.shrink();

    final running = ref.watch(commitProvider(widget.folder)) is CommitRunning;
    final alternatives = _alternatives(snapshot, action);
    if (alternatives.isEmpty) {
      return _Primary(action: action, running: running, onPressed: _run);
    }

    return MenuAnchor(
      controller: _menu,
      alignmentOffset: const Offset(0, 6),
      style: appMenuStyle(),
      menuChildren: alternatives,
      builder: (context, controller, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Primary(
            action: action,
            running: running,
            onPressed: _run,
            // Square the inner edge so the two halves read as one control.
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.horizontal(
                left: Radius.circular(AppControl.radius),
              ),
            ),
          ),
          const SizedBox(width: 1),
          _Caret(
            open: controller.isOpen,
            onPressed: running
                ? null
                : () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
          ),
        ],
      ),
    );
  }

  /// The actions the button *didn't* take, and only while they are possible: a
  /// menu listing what can't be done is a list of dead ends.
  List<Widget> _alternatives(ReviewSnapshot snapshot, CommitAction action) {
    final unticked = snapshot.files.length - snapshot.staged.length;
    final ahead = snapshot.ahead;
    return [
      if (action != CommitAction.commitAll &&
          snapshot.scope.canStage &&
          unticked > 0)
        MenuRow(
          label: 'Include every change',
          detail:
              'Tick $unticked more file${unticked == 1 ? '' : 's'}, '
              'then commit',
          icon: LucideIcons.listChecks,
          width: CommitButton.menuWidth,
          onTap: () => _run(CommitAction.commitAll),
        ),
      if (action != CommitAction.push && ahead > 0 && !snapshot.detached)
        MenuRow(
          label: 'Push what is committed',
          detail: '$ahead commit${ahead == 1 ? '' : 's'} on this computer only',
          icon: LucideIcons.arrowUp,
          width: CommitButton.menuWidth,
          onTap: () => _run(CommitAction.push),
        ),
    ];
  }

  /// Does [action], from whichever half of the control asked for it.
  Future<void> _run(CommitAction action) async {
    _menu.close();
    switch (action) {
      case CommitAction.commit:
        await showCommitSheet(context, folder: widget.folder);
      case CommitAction.commitAll:
        await _includeAllThenCommit();
      case CommitAction.push:
        await _pushOnly();
      case CommitAction.none:
        return;
    }
  }

  /// Tick every file on screen, then open the commit box — which is what the
  /// label promises, and why the sheet isn't shown when the ticking failed.
  Future<void> _includeAllThenCommit() async {
    final failure = await ref
        .read(reviewProvider(widget.folder).notifier)
        .stageAll();
    if (!mounted) return;
    if (failure != null) {
      showReviewFailure(context, failure);
      return;
    }
    await showCommitSheet(context, folder: widget.folder);
  }

  Future<void> _pushOnly() async {
    await ref.read(commitProvider(widget.folder).notifier).pushOnly();
    if (!mounted) return;
    final state = ref.read(commitProvider(widget.folder));
    if (state is CommitFailed) showReviewFailure(context, state.message);
  }
}

/// The half that does the thing — or the whole button when there is nothing
/// else to offer.
///
/// Disabled only while a commit or a push is in flight, so the two halves are
/// never lit differently: a bright caret beside a grey label reads as a broken
/// control rather than as one action being unavailable.
class _Primary extends StatelessWidget {
  const _Primary({
    required this.action,
    required this.running,
    required this.onPressed,
    this.shape,
  });

  final CommitAction action;
  final bool running;
  final ValueChanged<CommitAction> onPressed;

  /// Square on the inner edge when a caret sits beside it; the theme's own
  /// rounding when it stands alone.
  final OutlinedBorder? shape;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final button = FilledButton(
      style: FilledButton.styleFrom(
        shape: shape,
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
      onPressed: running ? null : () => onPressed(action),
      child: Text(action.label),
    );
    // "Commit all" is the one label that doesn't say its whole story — what
    // "all" covers is the list on screen, and the tooltip is where that fits.
    if (action != CommitAction.commitAll) return button;
    return Tooltip(
      message: 'Tick every file listed here, then commit',
      child: button,
    );
  }
}

/// The half that opens the menu.
class _Caret extends StatelessWidget {
  const _Caret({required this.open, required this.onPressed});

  final bool open;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return FilledButton(
      style: FilledButton.styleFrom(
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.horizontal(
            right: Radius.circular(AppControl.radius),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        minimumSize: const Size(0, 0),
      ),
      onPressed: onPressed,
      child: AnimatedRotation(
        duration: AppMotion.hover,
        curve: AppMotion.curve,
        turns: open ? 0.5 : 0,
        child: const Icon(LucideIcons.chevronDown, size: 13),
      ),
    );
  }
}
