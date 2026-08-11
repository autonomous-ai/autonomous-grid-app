import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';

/// The chrome every dialog in Code shares: a title, a close button, a fixed
/// content column and a Cancel/confirm pair.
///
/// One shell rather than four copies of the same paddings — the app's dialogs
/// have drifted apart that way before, and three of these sit one click from
/// each other.
class CodeDialog extends StatelessWidget {
  const CodeDialog({
    super.key,
    required this.title,
    required this.child,
    required this.confirmLabel,
    required this.onConfirm,
    this.busy = false,
    this.width = 480,
  });

  final String title;
  final Widget child;
  final String confirmLabel;

  /// Null disables the confirm button — the form is not complete yet.
  final VoidCallback? onConfirm;

  /// Work is in flight: both actions are held so a second press cannot start a
  /// second command, and the button says so rather than just going quiet.
  final bool busy;

  final double width;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return AlertDialog(
      backgroundColor: AppPalette.windowBg,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(28, 24, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(28, 16, 28, 4),
      actionsPadding: const EdgeInsets.fromLTRB(28, 12, 22, 22),
      title: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Close',
            iconSize: 20,
            color: AppPalette.textSecondary,
            icon: const Icon(Icons.close_rounded),
            onPressed: busy ? null : () => Navigator.of(context).pop(),
          ),
        ],
      ),
      content: SizedBox(
        // Clamped to the window, not fixed: a desktop window can be dragged
        // narrower than any dialog, and a fixed width there overflows into a
        // striped bar instead of a form somebody can fill in. The 96 is the
        // dialog's own margins either side plus its content padding.
        width: math.min(width, MediaQuery.sizeOf(context).width - 96),
        child: SingleChildScrollView(child: child),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 4),
        FilledButton(
          onPressed: busy ? null : onConfirm,
          child: Text(busy ? 'Working…' : confirmLabel),
        ),
      ],
    );
  }
}
