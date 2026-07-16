import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// The top bar's rounded "pill" chrome — a soft glass capsule with a hairline
/// rim and a lifted shadow.
///
/// Each top-bar surface wraps its *own* content in one and stays unmounted when
/// it has nothing to show, so the bar never renders an empty capsule floating on
/// its own.
class TopBarPill extends StatelessWidget {
  const TopBarPill({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Subscribe to the brightness directly: pills are `const`-mounted under the
    // top bar, so the bar's own rebuild is short-circuited before it reaches
    // here — without this a pill keeps its old fill/rim when the theme flips.
    AppTheme.watch(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppGlass.surfaceFill,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppGlass.hair),
        boxShadow: AppGlass.cardShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: child,
      ),
    );
  }
}
