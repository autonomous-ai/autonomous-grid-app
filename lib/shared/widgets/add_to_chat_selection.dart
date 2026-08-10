import 'package:flutter/gestures.dart' show kPrimaryButton, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
/// **One menu, whichever way you open it.** Letting go of a drag and
/// right-clicking both raise the same three rows in the app's own shape. They
/// used to raise two different menus — the app's single *Add to Chat* on a drag,
/// the platform's Copy/Select All strip on a right-click — and a surface that
/// answers one selection with two menus is one the user has to learn twice. The
/// platform strip is switched off — by building nothing, never by passing null,
/// see the builder below — and its two actions are done here instead: copy is
/// the text we already hold, and select all is
/// [SelectionAreaState.selectableRegion]'s own.
///
/// macOS shows nothing after a mouse drag by design (see `_handleMouseDragEnd`
/// in `selectable_region.dart`) and `SelectableRegion` keeps `_showToolbar`
/// private, so the menu has to be the app's either way.
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
  final _area = GlobalKey<SelectionAreaState>();
  String? _selected;

  /// What was highlighted when the menu went up.
  ///
  /// Read then rather than when a row is tapped, because the rows act on the
  /// selection the user was looking at when they opened it — and a region that
  /// loses focus to the menu clears its selection on the way (see
  /// `_handleFocusChanged` in `selectable_region.dart`), which would leave the
  /// menu standing over a highlight it could no longer send.
  String? _offered;

  /// Where the button went down and which one it was, so a release can tell a
  /// drag from a click — and a right-click from either.
  ({Offset at, bool secondary})? _pressed;

  String? get _selectedText {
    final text = _selected;
    return text != null && text.trim().isNotEmpty ? text : null;
  }

  void _down(PointerDownEvent event) {
    // A press anywhere puts the last menu away — including the press that
    // starts the next selection, which would otherwise leave two on screen.
    if (_menu.isOpen) _menu.close();
    _pressed = switch (event.buttons) {
      kPrimaryButton => (at: event.localPosition, secondary: false),
      kSecondaryButton => (at: event.localPosition, secondary: true),
      _ => null,
    };
  }

  void _up(PointerUpEvent event) {
    final from = _pressed;
    _pressed = null;
    if (from == null) return;
    // A left button that never travelled was a click, and a click inside a
    // selection is how you throw it away — not how you ask about it.
    if (!from.secondary &&
        (event.localPosition - from.at).distance < _dragSlop) {
      return;
    }
    // After the frame, for both gestures: a drag finalises its selection on
    // release, and a right-click on plain text selects the word under it, so
    // asking in the same event reads the *previous* answer.
    final at = event.localPosition;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final text = _selectedText;
      if (!mounted || text == null || _menu.isOpen) return;
      _offered = text;
      // Just below the pointer, so the menu doesn't land on the last words of
      // what was selected.
      _menu.open(position: at + const Offset(4, 8));
    });
  }

  void _add() {
    final text = _offered;
    _menu.close();
    // The selection stays highlighted so the user can see what they just sent;
    // only the menu goes, because standing there it would hide the chip
    // appearing below it.
    if (text != null) widget.onAdd?.call(text);
  }

  void _copy() {
    final text = _offered;
    _menu.close();
    if (text != null) Clipboard.setData(ClipboardData(text: text));
  }

  void _selectAll() {
    _menu.close();
    // Without a cause, which is the desktop path: passing `toolbar` would ask
    // the region to raise the platform strip this widget exists to replace.
    _area.currentState?.selectableRegion.selectAll();
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final canAdd = widget.onAdd != null;
    return MenuAnchor(
      controller: _menu,
      style: appMenuStyle().copyWith(
        minimumSize: const WidgetStatePropertyAll(Size(kSelectionMenuWidth, 0)),
      ),
      menuChildren: [
        SizedBox(
          width: kSelectionMenuWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // What this menu is *for* leads it. Copy and Select all are the
              // ones the platform would have given anyway, and they sit under a
              // rule so the row that is the app's own reads as the answer to
              // the drag rather than as a third clipboard command.
              if (canAdd) ...[
                AppMenuRow(
                  icon: LucideIcons.messageSquarePlus300,
                  label: 'Add to Chat',
                  onPressed: _add,
                ),
                const AppMenuRule(),
              ],
              AppMenuRow(
                icon: LucideIcons.copy300,
                label: 'Copy',
                onPressed: _copy,
              ),
              AppMenuRow(
                icon: LucideIcons.boxSelect300,
                label: 'Select all',
                onPressed: _selectAll,
              ),
            ],
          ),
        ),
      ],
      builder: (context, controller, child) => Listener(
        onPointerDown: _down,
        onPointerUp: _up,
        child: SelectionArea(
          key: _area,
          onSelectionChanged: (content) => _selected = content?.plainText,
          // Nothing: the menu above is the one this surface answers with, and
          // the platform's strip would be a second one for the same selection.
          //
          // An empty widget rather than `null`, which reads like the way to
          // say "no toolbar" and is a crash. `SelectableRegion._showToolbar`
          // calls `widget.contextMenuBuilder!` with no null check
          // (`selectable_region.dart:1384`), and it runs on a right-click and
          // on a double-click — so null took the whole window to the red
          // screen the moment anyone tried either.
          contextMenuBuilder: (_, _) => const SizedBox.shrink(),
          child: widget.child,
        ),
      ),
    );
  }
}
