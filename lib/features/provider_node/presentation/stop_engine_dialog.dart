import 'package:flutter/material.dart';

/// Ask before an engine stops serving.
///
/// One dialog for both ways to stop, because they do the same thing to the same
/// people: the row's own Stop and the header's. The header's used to fire on the
/// first click with no question asked — the more destructive of the two, since
/// it drops everything this machine shares — while the row beside it confirmed.
///
/// Returns true when the user said stop; false on cancel or a dismissed dialog.
Future<bool> confirmStopEngine(
  BuildContext context, {

  /// What's being stopped, in the user's words — "Local model", "ChatGPT /
  /// Codex", or a plain plural for several at once.
  required String what,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Stop $what?'),
      // No "your other engines keep running": this computer shares one engine
      // (see `connectBlockedReason`), so stopping is always all of it.
      content: const Text(
        'It will stop serving on the grid, so others can no longer use it. '
        'You can share it again from this page whenever you like.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Stop'),
        ),
      ],
    ),
  );
  return ok ?? false;
}
