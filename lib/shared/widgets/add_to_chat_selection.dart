import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/app_theme.dart';
import 'app_menu_row.dart';
import 'labeled_field.dart';

/// How far the pointer must travel before a press counts as picking text out.
///
/// A click *inside* a selection is how you dismiss it, and a click that landed
/// a pixel off centre must not be read as a fresh drag — that would pop the menu
/// over a selection the user was in the middle of throwing away.
const double _dragSlop = 6;

/// Selectable text that offers **Add to Chat** the moment a selection is made.
///
/// Shared by every surface a user reads code on — the file viewer, a diff —
/// because it is one gesture and one sentence. Two copies of it would answer the
/// same drag with different words within a release (§5).
///
/// Two ways in, because they answer different habits:
///
///  - **Let go of the drag** and the app's own one-item menu appears where the
///    pointer stopped. This is the affordance the feature is for; macOS shows
///    nothing after a mouse drag by design (see `_handleMouseDragEnd` in
///    `selectable_region.dart`), and `SelectableRegion` keeps its `_showToolbar`
///    private, so the menu here is the app's rather than the platform's.
///  - **Right-click** and the platform's own strip appears, with Copy and Select
///    All where the user expects them and *Add to Chat* appended. Replacing that
///    one would mean re-implementing two behaviours nobody asked to change.
///
/// The selected text is kept in a plain field rather than in state: it changes
/// on every tick of a drag, and rebuilding a two-thousand-line file to remember
/// a string no menu has asked for yet is work for nothing.
class AddToChatSelection extends StatefulWidget {
  const AddToChatSelection({
    super.key,
    required this.onAdd,
    required this.child,
  });

  /// Null when the surface has nowhere to put a selection, and then there is no
  /// menu on release and the right-click one is exactly the platform's own.
  final ValueChanged<String>? onAdd;

  final Widget child;

  @override
  State<AddToChatSelection> createState() => _AddToChatSelectionState();
}

class _AddToChatSelectionState extends State<AddToChatSelection> {
  final _menu = MenuController();
  String? _selected;

  /// Where the *left* button went down, so a release can tell a drag from a
  /// click. Null for any other button: a right-click has its own menu, and a
  /// right-drag must not open a second one over it.
  Offset? _pressed;

  String? get _addable {
    final text = _selected;
    if (widget.onAdd == null) return null;
    return text != null && text.trim().isNotEmpty ? text : null;
  }

  void _down(PointerDownEvent event) {
    // A press anywhere puts the last menu away — including the press that
    // starts the next selection, which would otherwise leave two on screen.
    if (_menu.isOpen) _menu.close();
    _pressed = event.buttons == kPrimaryButton ? event.localPosition : null;
  }

  void _up(PointerUpEvent event) {
    final from = _pressed;
    _pressed = null;
    if (from == null) return;
    if ((event.localPosition - from).distance < _dragSlop) return;

    // After the frame: the selection is finalised on drag end, and asking for it
    // in the same event that ended the drag reads the *previous* answer.
    final at = event.localPosition;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _addable == null || _menu.isOpen) return;
      // Just below the pointer, so the menu doesn't land on the last words of
      // what was selected.
      _menu.open(position: at + const Offset(4, 8));
    });
  }

  void _add() {
    final text = _addable;
    _menu.close();
    if (text != null) widget.onAdd!(text);
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return MenuAnchor(
      controller: _menu,
      style: appMenuStyle().copyWith(
        minimumSize: const WidgetStatePropertyAll(Size(_selectionMenuWidth, 0)),
      ),
      menuChildren: [
        SizedBox(
          width: _selectionMenuWidth,
          child: AppMenuRow(
            icon: LucideIcons.messageSquarePlus300,
            label: 'Add to Chat',
            onPressed: _add,
          ),
        ),
      ],
      builder: (context, controller, child) => Listener(
        onPointerDown: _down,
        onPointerUp: _up,
        child: SelectionArea(
          onSelectionChanged: (content) => _selected = content?.plainText,
          contextMenuBuilder: (context, selection) {
            final text = _addable;
            return AdaptiveTextSelectionToolbar.buttonItems(
              anchors: selection.contextMenuAnchors,
              buttonItems: [
                ...selection.contextMenuButtonItems,
                if (text != null)
                  ContextMenuButtonItem(
                    label: 'Add to Chat',
                    onPressed: () {
                      // The strip goes first: the selection stays highlighted so
                      // the user can see what they just sent, but a menu left
                      // standing over it would hide the chip appearing below.
                      selection.hideToolbar();
                      widget.onAdd!(text);
                    },
                  ),
              ],
            );
          },
          child: widget.child,
        ),
      ),
    );
  }
}

const double _selectionMenuWidth = 168;
