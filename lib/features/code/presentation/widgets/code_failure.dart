import 'package:flutter/material.dart';

import '../../../../shared/widgets/error_box.dart';

/// A failure with the one action that can clear it.
///
/// The grid's commands are not retried behind the user's back — a refusal is a
/// verdict, and asking again ten times only spends processes — so the way out
/// has to be a button they can see.
class CodeFailure extends StatelessWidget {
  const CodeFailure({super.key, required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ErrorBox(message: message),
      const SizedBox(height: 10),
      OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
    ],
  );
}
