import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A small caps label carrying a fact *about* the thing beside it — "NO SETUP"
/// on a choice, "1 OF 2 STEPS" on a header.
///
/// Deliberately no fill and no border: a chip next to a chevron reads as a
/// second target on a row that only has one. Size, caps and tracking are what
/// mark it as a label, so it never has to borrow contrast to do it — it stays on
/// [AppPalette.textSecondary], which clears 4.5:1 where the faint grey lands
/// near 3.3 (§11).
class MetaLabel extends StatelessWidget {
  const MetaLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.7,
        color: AppPalette.textSecondary,
      ),
    );
  }
}
