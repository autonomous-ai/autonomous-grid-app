import 'package:flutter/material.dart';

/// [showDialog], with the dialog's own words selectable.
///
/// The app mounts one [SelectionArea] over everything (`grid_app.dart`), and a
/// dialog is the one thing it cannot reach: `showDialog` pushes a route, and a
/// route is a **sibling** entry in the navigator's overlay rather than a
/// descendant of whatever was on screen when it opened. So the member list in
/// "Who can use…" — a screenful of email addresses, which is about the most
/// copyable thing this app displays — could be read and not taken.
///
/// **Why not one region above the navigator instead.** `MaterialApp.builder`
/// wraps the navigator, and a `SelectableRegion` mounted there has no `Overlay`
/// above it; both branches of `SelectionOverlay.showToolbar` resolve
/// `Overlay.of(context, rootOverlay: true)`, so the right-click that opens Copy
/// would throw. Measured against Flutter 3.44's source, not assumed. Inside a
/// route the lookup succeeds, which is why the region belongs *here*, once per
/// dialog, rather than once for the app.
///
/// Use this instead of `showDialog` for anything with words in it. A dialog that
/// is one sentence and two buttons loses nothing by using it either, so there is
/// no judgement call at the call site — the rule is simply "dialogs open with
/// this".
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
}) => showDialog<T>(
  context: context,
  barrierDismissible: barrierDismissible,
  barrierColor: barrierColor,
  useRootNavigator: useRootNavigator,
  routeSettings: routeSettings,
  builder: (context) => SelectionArea(child: builder(context)),
);
