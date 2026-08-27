import 'package:flutter/material.dart';

/// The selectable contents of a scrolling page — **placed inside the scroll
/// view, never around it**.
///
/// The app already has one [SelectionArea] over everything (`grid_app.dart`),
/// and for anything that does not scroll that is enough. It is not enough for a
/// page body, and the reason is a single line in the framework: a `Scrollable`
/// that finds a selection registrar overhead wraps itself in
/// `_ScrollableSelectionContainerDelegate` (`scrollable.dart`), and on this
/// app's pages that delegate answers every drag with an empty selection. The
/// region wins the gesture — measured with `debugPrintGestureArenaDiagnostics`,
/// which named `TapAndPanGestureRecognizer` the winner — and then selects
/// nothing, silently, with no exception to go on. Cmd+A kept working the whole
/// time, because select-all never asks the delegate to turn a pointer position
/// into a selectable.
///
/// Mounted **below** the scroll view, the plain `StaticSelectionContainerDelegate`
/// runs instead and a drag behaves. So the rule is the placement, and this
/// widget exists to make the rule greppable rather than a comment somebody
/// copies wrong:
///
/// ```dart
/// ListView(children: [SelectableBody(child: Column(children: rows))])
/// SingleChildScrollView(child: SelectableBody(child: body))
/// ```
///
/// **What it costs.** A selection cannot span two regions, so a drag that starts
/// in the page heading — which belongs to the app-wide region — and ends in the
/// body stops at the boundary. Each half selects on its own, and Cmd+A still
/// takes whichever one has focus.
///
/// **Not for a lazy list.** `ListView.builder` has no single child to wrap, and
/// one of these per row would build a `SelectableRegion` — focus node, gesture
/// recognisers and all — for every row that scrolls into view. That is the same
/// trade `message_content.dart` refused for `SelectableText`, and it is refused
/// here for the same reason. A lazy list's text stays as selectable as its own
/// widgets make it.
class SelectableBody extends StatelessWidget {
  const SelectableBody({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SelectionArea(child: child);
}
