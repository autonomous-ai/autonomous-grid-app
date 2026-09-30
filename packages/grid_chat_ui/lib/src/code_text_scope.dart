import 'package:flutter/material.dart';

/// Holds a code surface at the user's *code* size, out of reach of the UI scale.
///
/// The two font-size settings are independent by design: a user who wants
/// larger chrome and compact code (or the reverse) has to be able to say so.
/// The UI size reaches every `Text` in the app through `MediaQuery`'s text
/// scaler, so a code block that also sized itself from `AppFont.codeSize` would
/// get the setting applied twice — UI 19 with code 12 would render code at ~16.
///
/// Wrap the surface in this, then size its text with `AppFont.codeStyle()`, and
/// the number the user typed is the number that renders.
///
/// Only for surfaces that are *made of* code — a diff, a log pane, a code block,
/// a terminal-style readout. A model id sitting inline in a settings row is
/// prose-adjacent: it takes the mono family but stays on the UI scale with the
/// sentence around it.
class CodeTextScope extends StatelessWidget {
  const CodeTextScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      MediaQuery.withNoTextScaling(child: child);
}
