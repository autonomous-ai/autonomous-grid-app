import 'package:flutter/material.dart';

import '../../../../shared/theme/app_theme.dart';

/// A quiet line where a group of rail rows would be — loading, empty, or a
/// failure. Inset like a row so the rail keeps its rhythm either way.
///
/// [onRetry] is what turns a dead end into a state somebody can leave: the grid
/// commands behind these rows are not retried automatically (a refusal is a
/// verdict, and asking again ten times only spends processes), so the one way
/// back has to be on screen.
class RailNote extends StatelessWidget {
  const RailNote(this.message, {super.key, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: TextStyle(
              color: AppPalette.textFaint,
              fontSize: 12,
              height: 1.35,
            ),
          ),
          if (onRetry != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: TextButton(
                onPressed: onRetry,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Try again'),
              ),
            ),
        ],
      ),
    );
  }
}
