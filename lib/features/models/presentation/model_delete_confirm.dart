import 'package:flutter/material.dart';

import '../../../shared/widgets/app_dialog.dart';
import '../../../shared/theme/app_theme.dart';
import '../logic/model_storage.dart';

/// Widest the message is allowed to get, so the whole dialog stops at 500 with
/// the 24pt of content padding on each side.
///
/// An [AlertDialog] takes the width its content asks for, and one long sentence
/// asks for one long line — on a desktop window that stretched the dialog most
/// of the way across the screen instead of wrapping.
const _messageMaxWidth = 452.0;

/// Asks before removing files from the user's disk — the one confirmation both
/// the version panel and the storage list use, so the question is worded the
/// same wherever a delete starts.
///
/// Anything but an explicit yes (Cancel, Escape, a tap outside) returns false.
///
/// [unfinished] changes what is actually being lost: a finished model can be
/// downloaded again, while deleting the part of one that never finished throws
/// away the progress it had made, so the next download starts from zero. Saying
/// only "you can download it again" there would be true and still misleading.
Future<bool> confirmModelDelete(
  BuildContext context, {
  required String label,
  required int sizeBytes,
  required bool unfinished,
}) async {
  final size = modelSizeLabel(sizeBytes);
  final confirmed = await showAppDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(
        unfinished ? 'Delete this unfinished download?' : 'Delete this model?',
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _messageMaxWidth),
        child: Text(
          unfinished
              ? 'The $size of "$label" already downloaded will be removed, '
                    'freeing that space. There will be nothing left to carry on '
                    'from — downloading it again starts from the beginning.'
              : '"$label" will be removed from this computer, freeing $size. '
                    'You can download it again any time.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: dangerButtonStyle(),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return confirmed == true;
}
