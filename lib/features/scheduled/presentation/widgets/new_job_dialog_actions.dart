part of 'new_job_dialog.dart';

class _DialogActions extends StatelessWidget {
  const _DialogActions({
    required this.saving,
    required this.canSave,
    required this.onCancel,
    required this.onSave,
  });

  final bool saving;
  final bool canSave;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: saving ? null : onCancel,
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: canSave ? onSave : null,
          style: FilledButton.styleFrom(
            minimumSize: const Size(124, 38),
            shape: const StadiumBorder(),
          ),
          child: Text(saving ? 'Saving…' : 'Schedule it'),
        ),
      ],
    );
  }
}
