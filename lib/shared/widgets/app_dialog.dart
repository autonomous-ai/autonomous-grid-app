import 'package:flutter/material.dart';

/// [showDialog], as the one door every dialog in the app opens through.
///
/// It adds no behaviour of its own today — it forwards each argument
/// unchanged. What it buys is the funnel: 53 call sites that used to reach for
/// `showDialog` by hand now name one function, so a default that has to change
/// for every dialog at once (a barrier colour, a route setting, a wrapper the
/// navigator needs) is changed here rather than hunted for.
///
/// It did carry a `SelectionArea`, so a dialog's words could be copied — a
/// dialog is a sibling route in the navigator's overlay, not a descendant of
/// the screen behind it, so the app-wide region never reached inside one. That
/// region went with the app-wide one on 2026-09-09 (`e2a9aa50`): selecting the
/// chrome is what a web page does, not a desktop app. A dialog that genuinely
/// needs its text taken — a list of email addresses, a token — asks for it
/// where it is shown, with a `SelectableText`.
///
/// Use this rather than `showDialog` directly, so the funnel stays whole.
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
  builder: builder,
);
