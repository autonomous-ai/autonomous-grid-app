part of 'add_mcp_dialog.dart';

/// The dialog's buttons, which differ per stage.
class _DialogActions extends StatelessWidget {
  const _DialogActions({
    required this.stage,
    required this.saving,
    required this.signingIn,
    required this.primary,
    required this.onCancel,
    required this.onBack,
  });

  final _Stage stage;
  final bool saving;

  /// The browser is open on a sign-in — the left button stops being "Back".
  final bool signingIn;

  /// The button that moves the dialog on: what it says, and what it does (null
  /// while it can't). Decided by the dialog, since which of the four it is
  /// depends on the stage *and* on what the probe found.
  final ({String label, VoidCallback? onPressed}) primary;

  final VoidCallback onCancel;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    // Nothing to press while the network is being asked. Cancel stays, because
    // a probe against a dead host runs out its timeout and the user should not
    // have to wait for it.
    if (stage == _Stage.checking) {
      return TextButton(onPressed: onBack, child: const Text('Cancel'));
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // While the browser is open the left button stops being "Back" and
        // becomes the way out — and stays live whatever else is happening.
        // Back would be wrong there: there is a sign-in in flight, and
        // returning to the form would leave it running behind a screen that no
        // longer mentions it.
        if (stage == _Stage.found && signingIn)
          TextButton(onPressed: onCancel, child: const Text('Cancel'))
        else if (stage == _Stage.found)
          TextButton(
            onPressed: saving ? null : onBack,
            child: const Text('Back'),
          )
        else
          TextButton(
            onPressed: saving ? null : onCancel,
            child: const Text('Cancel'),
          ),
        const SizedBox(width: 4),
        FilledButton(onPressed: primary.onPressed, child: Text(primary.label)),
      ],
    );
  }
}
