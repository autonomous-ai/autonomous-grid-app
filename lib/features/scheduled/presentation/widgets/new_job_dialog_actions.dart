part of 'new_job_dialog.dart';

class _DialogActions extends StatelessWidget {
  const _DialogActions({
    required this.saving,
    required this.canSave,
    required this.saveLabel,
    required this.onCancel,
    required this.onSave,
    required this.onTryNow,
  });

  final bool saving;
  final bool canSave;

  /// What the commit button says — the form both creates and edits, and
  /// "Schedule it" over a task that has been running for a month reads as a
  /// second copy about to be made.
  final String saveLabel;

  final VoidCallback onCancel;
  final VoidCallback onSave;

  /// Save and run one pass right away — a "see it work before you trust it"
  /// that saves the user from creating the task, finding it, and hitting Run.
  /// Null while editing: that task already has Run now on its own screen.
  final VoidCallback? onTryNow;

  @override
  Widget build(BuildContext context) {
    final tryNow = onTryNow;
    return Row(
      children: [
        // Try it now leads the row, left-aligned: it's the reassuring path, kept
        // visually apart from the commit-to-a-schedule button on the right.
        if (tryNow != null)
          OutlinedButton.icon(
            onPressed: canSave ? tryNow : null,
            icon: const Icon(
              Icons.play_arrow_rounded,
              size: AppControl.iconSize,
            ),
            label: const Text('Try it now'),
          ),
        const Spacer(),
        TextButton(
          onPressed: saving ? null : onCancel,
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: canSave ? onSave : null,
          child: Text(saving ? 'Saving…' : saveLabel),
        ),
      ],
    );
  }
}
