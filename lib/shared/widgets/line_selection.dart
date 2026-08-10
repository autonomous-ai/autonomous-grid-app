import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Keeps the line breaks a column of one-line widgets implies.
///
/// A selection over a list is flattened by writing each child's selected text
/// into one buffer with nothing in between, so three lines of a diff come out as
/// `abcdefghi`. Everything downstream is then wrong in the same way — ⌘C pastes
/// one run-on line, and so does the text handed to an assistant.
///
/// A file viewer doesn't need this: its source is one `Text`, and the newlines
/// are inside it. A diff draws a widget per row, and this is what puts them
/// back. Wrap the scrolling list, inside whatever provides the selection
/// itself.
///
/// Rows that aren't part of the text — a line-number gutter, a hunk heading —
/// belong in `SelectionContainer.disabled`, so they stay out of both the
/// highlight and what comes back from it.
class LineSelection extends StatefulWidget {
  const LineSelection({super.key, required this.child});

  final Widget child;

  @override
  State<LineSelection> createState() => _LineSelectionState();
}

class _LineSelectionState extends State<LineSelection> {
  final _LineJoiningDelegate _delegate = _LineJoiningDelegate();

  @override
  void dispose() {
    _delegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SelectionContainer(delegate: _delegate, child: widget.child);
}

/// The framework's own delegate, with the newline the list implies put back
/// between its children.
///
/// [StaticSelectionContainerDelegate] is what [SelectableRegion] itself runs on,
/// children coming and going with the scroll included, so only the one method
/// that flattens the selection is overridden here.
class _LineJoiningDelegate extends StaticSelectionContainerDelegate {
  @override
  SelectedContent? getSelectedContent() {
    final lines = [
      for (final selectable in selectables)
        if (selectable.getSelectedContent() case final SelectedContent line)
          line.plainText,
    ];
    if (lines.isEmpty) return null;
    return SelectedContent(plainText: lines.join('\n'));
  }
}
