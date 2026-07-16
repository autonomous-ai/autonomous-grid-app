import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The one set of numbers every spinner in the app is built from.
///
/// Before this existed, `SizedBox(width: N, height: N, child:
/// CircularProgressIndicator(strokeWidth: 2))` was retyped at 38 call sites with
/// six different N (12, 14, 15, 16, 18, 22) and three stroke widths. The 15 was
/// nobody's decision — it's what happens when there's no token to reach for.
///
/// Worse, a dozen sites wrote the bare `CircularProgressIndicator()` with no
/// size at all, which Material renders at 36px with a 4px stroke: a heavy ring
/// in an app whose every other spinner is ≤22px and hairline-thin.
///
/// Change a number here, not at a call site.
enum SpinnerSize {
  /// Inside a dense row — a step's status glyph, a list item's trailing state.
  small(12, 1.6),

  /// The default: button spinners, inline row states. Sits on the cap height of
  /// a 13pt label.
  medium(16, 2),

  /// A pane or page waiting on its first load, and media placeholders.
  large(22, 2);

  const SpinnerSize(this.extent, this.strokeWidth);

  /// Both the width and the height — a spinner is always square.
  final double extent;
  final double strokeWidth;
}

/// The app's progress ring, at one of three sanctioned sizes.
///
/// Prefer this over a raw [CircularProgressIndicator] everywhere: it carries the
/// size/stroke pairing so a spinner in a button and a spinner in a list read as
/// the same family.
class AppSpinner extends StatelessWidget {
  const AppSpinner({super.key, this.size = SpinnerSize.medium, this.color});

  final SpinnerSize size;

  /// Defaults to the theme's accent. Pass this only when the spinner sits on a
  /// coloured fill (e.g. white, on a filled accent button).
  final Color? color;

  /// The spinner that goes inside a [FilledButton] while it works — white, so it
  /// reads on the accent fill, and sized to the label it replaces.
  const AppSpinner.onAccent({super.key, this.size = SpinnerSize.medium})
    : color = Colors.white;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return SizedBox(
      width: size.extent,
      height: size.extent,
      child: CircularProgressIndicator(
        strokeWidth: size.strokeWidth,
        color: color ?? AppPalette.accent,
      ),
    );
  }
}

/// A pane waiting on its first load: a centred [SpinnerSize.large] ring with an
/// optional line of text under it.
///
/// This replaces the `Center(child: CircularProgressIndicator())` that seven
/// screens each wrote by hand — which rendered the 36px/stroke-4 Material
/// default and was the app's loudest visual inconsistency.
///
/// Reach for a [Skeleton] instead when you know the shape of what's arriving;
/// this is for when you don't.
class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppSpinner(size: SpinnerSize.large),
          if (message != null) ...[
            const SizedBox(height: 12),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppPalette.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The app's determinate/indeterminate progress bar, always with the rounded
/// ends and 4px height that two of the five original call sites had and three
/// had silently dropped.
class AppProgressBar extends StatelessWidget {
  const AppProgressBar({super.key, this.value, this.color});

  /// 0..1, or null for indeterminate.
  final double? value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(
        value: value,
        minHeight: 4,
        color: color ?? AppPalette.accent,
        backgroundColor: AppPalette.divider,
      ),
    );
  }
}
