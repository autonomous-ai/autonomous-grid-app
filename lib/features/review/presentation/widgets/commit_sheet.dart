import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/error_box.dart';
import '../../../../shared/widgets/labeled_field.dart';
import '../../../../shared/widgets/toast.dart';
import '../../logic/commit_controller.dart';
import '../../logic/review_controller.dart';
import '../../logic/review_snapshot.dart';

/// Record the staged changes as a commit, and optionally send them on.
///
/// Opens on a clean slate: the controller outlives the dialog, so a failure
/// from the last attempt would otherwise be the first thing the user sees.
Future<void> showCommitSheet(BuildContext context, {required String folder}) =>
    showDialog<void>(
      context: context,
      builder: (_) => CommitSheet(folder: folder),
    );

class CommitSheet extends ConsumerStatefulWidget {
  const CommitSheet({super.key, required this.folder});

  final String folder;

  @override
  ConsumerState<CommitSheet> createState() => _CommitSheetState();
}

class _CommitSheetState extends ConsumerState<CommitSheet> {
  final _message = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Not in build: Riverpod forbids mutating a provider while one is being
    // built, and this has to happen once per opening.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(commitProvider(widget.folder).notifier).reset();
    });
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final state = ref.watch(commitProvider(widget.folder));
    final ready = ref.watch(reviewProvider(widget.folder)).value;
    final snapshot = ready is ReviewReady ? ready.snapshot : null;
    final running = state is CommitRunning;

    ref.listen(commitProvider(widget.folder), (_, next) => _onDone(next));

    return AlertDialog(
      title: const Text('Commit'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (snapshot != null) _Summary(snapshot: snapshot),
            const SizedBox(height: 12),
            LabeledField(
              label: 'What does this change do?',
              controller: _message,
              hint: 'Fix the login button on small windows',
              enabled: !running,
              autofocus: true,
              minLines: 2,
              maxLines: 4,
              onChanged: (_) => setState(() {}),
            ),
            if (state is CommitRunning) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const AppSpinner(size: SpinnerSize.small),
                  const SizedBox(width: 8),
                  Text(
                    state.step,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppPalette.textSecondary,
                    ),
                  ),
                ],
              ),
            ],
            if (state is CommitFailed) ...[
              const SizedBox(height: 12),
              ErrorBox(message: state.message, maxHeight: 140),
              if (state.committed) ...[
                const SizedBox(height: 8),
                Text(
                  'The commit itself was made — only sending it on failed, so '
                  'there is no need to commit again.',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: AppPalette.textSecondary,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: running ? null : () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(
            foregroundColor: AppPalette.textSecondary,
          ),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: running || _message.text.trim().isEmpty
              ? null
              : () => _run(push: false),
          child: const Text('Commit'),
        ),
        FilledButton(
          onPressed: running || _message.text.trim().isEmpty
              ? null
              : () => _run(push: true),
          child: running
              ? const AppSpinner.onAccent()
              : Text(_pushLabel(snapshot)),
        ),
      ],
    );
  }

  /// What the primary button promises. It has to name the branch it will push
  /// to when there is one — "Commit & push" on a detached HEAD would be a
  /// promise the repository can't keep.
  String _pushLabel(ReviewSnapshot? snapshot) =>
      snapshot?.detached ?? false ? 'Commit' : 'Commit & push';

  Future<void> _run({required bool push}) async {
    final snapshot = _snapshot();
    await ref
        .read(commitProvider(widget.folder).notifier)
        .run(
          message: _message.text,
          // Pushing from a detached HEAD has no branch to push; the button
          // already says so, and this is what keeps the two in step.
          push: push && !(snapshot?.detached ?? false),
        );
  }

  ReviewSnapshot? _snapshot() {
    final ready = ref.read(reviewProvider(widget.folder)).value;
    return ready is ReviewReady ? ready.snapshot : null;
  }

  /// Close on success and say what happened, in the words of what actually
  /// took place — "Committed" when only that was asked for.
  void _onDone(CommitState state) {
    if (state is! CommitDone || !mounted) return;
    final toast = ToastScope.of(context);
    Navigator.of(context).pop();
    toast?.show(
      ToastSpec(
        message: state.pushed
            ? 'Committed and pushed “${state.branch}”.'
            : 'Committed. It is on this computer only until you push.',
        severity: ToastSeverity.success,
      ),
    );
  }
}

/// What this commit will carry.
class _Summary extends StatelessWidget {
  const _Summary({required this.snapshot});

  final ReviewSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final staged = snapshot.staged;
    final names = staged.map((file) => file.name).take(3).join(', ');
    final rest = staged.length - 3;
    return Text(
      staged.isEmpty
          ? 'Nothing is ticked, so this commit would be empty.'
          : '${staged.length} file${staged.length == 1 ? '' : 's'}: $names'
                '${rest > 0 ? ' and $rest more' : ''}',
      style: TextStyle(
        fontSize: 12.5,
        height: 1.35,
        color: AppPalette.textSecondary,
      ),
    );
  }
}
