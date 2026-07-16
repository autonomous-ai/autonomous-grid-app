part of 'new_job_dialog.dart';

class _DialogActions extends StatelessWidget {
  const _DialogActions({
    required this.saving,
    required this.canSave,
    required this.onCancel,
    required this.onSave,
    required this.onTryNow,
  });

  final bool saving;
  final bool canSave;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  /// Save and run one pass right away — a "see it work before you trust it"
  /// that saves the user from creating the task, finding it, and hitting Run.
  final VoidCallback onTryNow;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // Try it now leads the row, left-aligned: it's the reassuring path, kept
        // visually apart from the commit-to-a-schedule button on the right.
        OutlinedButton.icon(
          onPressed: canSave ? onTryNow : null,
          icon: const Icon(Icons.play_arrow_rounded, size: AppControl.iconSize),
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
          child: Text(saving ? 'Saving…' : 'Schedule it'),
        ),
      ],
    );
  }
}
