/// What a screen shows when its answer from the computer is not a list: a
/// failure with the way to try again, a plain note when there is nothing, and
/// the pull that asks again.
///
/// One copy of each. Every tab had its own `_Problem` with the same text style
/// and the same button — three of them, one edit away from saying three
/// different things.
library;

import 'package:flutter/material.dart';
import 'package:grid_theme/grid_theme.dart';

/// A failure, in the computer's words, with a Try again under it.
class LoadProblem extends StatelessWidget {
  const LoadProblem({required this.message, required this.onRetry, super.key});

  /// Shown as-is — the link's own sentence, never a stack trace.
  final String message;

  /// Asking again.
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QuietNote(message),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

/// One centred line of secondary text — an empty list, saying what to do.
class QuietNote extends StatelessWidget {
  const QuietNote(this.text, {super.key});

  /// What there is to say.
  final String text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Text(
      text,
      textAlign: TextAlign.center,
      style: Theme.of(
        context,
      ).textTheme.bodyMedium?.copyWith(color: AppPalette.textSecondary),
    );
  }
}

/// [QuietNote] filling a screen, padded away from its edges.
class EmptyNote extends StatelessWidget {
  const EmptyNote(this.text, {super.key});

  /// What there is to say.
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(padding: const EdgeInsets.all(32), child: QuietNote(text)),
  );
}

/// Pull down to ask the computer again — the gesture every phone list has.
///
/// Takes any child, scrollable or not: an empty list or an error is a centred
/// note rather than a list, and a pull that only worked when there was
/// something to show would be missing exactly when somebody reaches for it.
class PullToRefresh extends StatelessWidget {
  const PullToRefresh({
    required this.onRefresh,
    required this.child,
    this.scrollable = true,
    super.key,
  });

  /// Asks again; the spinner stays until it completes.
  final Future<void> Function() onRefresh;

  /// What is being refreshed.
  final Widget child;

  /// Whether [child] already scrolls. When it does not, it is put in a
  /// scroll view the height of the screen so the pull has something to drag.
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return RefreshIndicator(
      color: AppPalette.accentOnSurface,
      onRefresh: onRefresh,
      child: scrollable ? child : _Draggable(child),
    );
  }
}

class _Draggable extends StatelessWidget {
  const _Draggable(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: box.maxHeight),
        child: child,
      ),
    ),
  );
}
