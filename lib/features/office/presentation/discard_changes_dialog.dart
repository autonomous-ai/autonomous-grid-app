import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/labeled_field.dart';

/// Asks before replacing a document that has edits the file doesn't have yet.
///
/// It asks rather than offering an undo, because there is nothing to undo: the
/// edits live only in the editor until Save writes them into the `.docx`, so
/// opening another document is the one click in Docs that can lose somebody's
/// work. Returns true when the user chose to go ahead.
///
/// Wears the same shape as the app's other confirmations (see
/// `confirmDeleteChat`) — lifted surface, 20px corners, the destructive choice in
/// the danger fill rather than the accent.
Future<bool> confirmDiscardChanges(BuildContext context, String name) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) {
      AppTheme.watch(context);
      final theme = Theme.of(context);
      return AlertDialog(
        backgroundColor: appMenuFill(),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: AppGlass.hair),
        ),
        titlePadding: const EdgeInsets.fromLTRB(28, 26, 28, 0),
        contentPadding: const EdgeInsets.fromLTRB(28, 12, 28, 4),
        actionsPadding: const EdgeInsets.fromLTRB(28, 16, 22, 22),
        title: Text(
          'Leave your changes behind?',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        content: SizedBox(
          width: 420,
          child: Text(
            'Your edits to "$name" are not in the file yet. Opening another '
            'document loses them.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppPalette.textSecondary,
              height: 1.45,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 4),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppPalette.dangerFill,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Open anyway'),
          ),
        ],
      );
    },
  );
  return ok ?? false;
}
