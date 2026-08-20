import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../logic/chat_sessions_controller.dart';
import '../logic/chat_title.dart';

/// The box both states wear — see [_TitleBox]. Small numbers, but they have to
/// be the *same* numbers on the label and on the field, or opening the field
/// nudges the title sideways.
const _hPad = 5.0;
const _vPad = 3.0;
const _boxRadius = 7.0;

/// The narrowest the field draws. It sizes itself to its text, and a chat named
/// down to two letters would otherwise leave a box too small to click back into.
const _fieldMinWidth = 72.0;

/// The title's one type style, read by the label and the field alike: same
/// size, same weight, same line height, so the words don't shift a pixel when
/// one replaces the other.
TextStyle _titleStyle() => TextStyle(
  color: AppPalette.textPrimary,
  fontSize: 13.5,
  fontWeight: AppFont.medium,
  height: 1.2,
);

/// The chat's name in the top bar, renamed in place.
///
/// Double-click turns the label into a field: Enter or a click anywhere else
/// keeps what was typed, Escape puts the old name back. Renaming is the one
/// thing people do to a title they are already looking at, so it happens where
/// they are looking — the "…" menu's dialog stays for the same rename reached
/// without a double-click.
class ChatHeaderTitle extends ConsumerStatefulWidget {
  const ChatHeaderTitle({super.key, required this.id, required this.title});

  /// Which conversation is being named. The rename goes to this id rather than
  /// to whatever happens to be active when the field closes.
  final String id;

  /// The name as it stands, shown as a label and seeded into the field.
  final String title;

  @override
  ConsumerState<ChatHeaderTitle> createState() => _ChatHeaderTitleState();
}

class _ChatHeaderTitleState extends ConsumerState<ChatHeaderTitle> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    // Covers the ways focus leaves that aren't a click in this window — Tab,
    // or the app being sent to the back mid-edit.
    _focus.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant ChatHeaderTitle old) {
    super.didUpdateWidget(old);
    // Switching conversations mid-edit: the field was naming the chat that just
    // left the bar, so it closes instead of stamping that name on the new one.
    if (old.id != widget.id) _editing = false;
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (_focus.hasFocus) return;
    _commit();
  }

  void _startEditing() {
    _controller.text = editableChatTitle(widget.title);
    // Selected, not just placed: the usual rename replaces the whole
    // auto-generated name, and leaving the caret at the end makes that a
    // select-all first. Anchored backwards (extent at 0) so a name too long for
    // the bar opens showing its *start* — the field scrolls to the extent, and
    // the other way round hands the user the tail of their own title.
    _controller.selection = TextSelection(
      baseOffset: _controller.text.length,
      extentOffset: 0,
    );
    setState(() => _editing = true);
  }

  /// Keeps what was typed. A blank name is the one value a chat can't wear, so
  /// it falls back to the title that was already there rather than clearing it.
  void _commit() {
    if (!_editing) return;
    final name = _controller.text.trim();
    setState(() => _editing = false);
    if (name.isEmpty || name == widget.title) return;
    ref.read(chatSessionsProvider.notifier).renameConversation(widget.id, name);
  }

  void _cancel() {
    if (!_editing) return;
    setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    if (!_editing) {
      return _TitleLabel(title: widget.title, onEdit: _startEditing);
    }
    return _TitleField(
      controller: _controller,
      focusNode: _focus,
      onSubmit: _commit,
      onCancel: _cancel,
    );
  }
}

/// The resting state: the name, and a double-click that opens it for editing.
class _TitleLabel extends StatelessWidget {
  const _TitleLabel({required this.title, required this.onEdit});

  final String title;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return GestureDetector(
      // Double-click only. A single click on the title does nothing here, and
      // the strip underneath is the window's drag handle — one click has to
      // stay free for it.
      onDoubleTap: onEdit,
      behavior: HitTestBehavior.opaque,
      child: Tooltip(
        message: 'Double-click to rename',
        waitDuration: const Duration(milliseconds: 700),
        child: _TitleBox(
          editing: false,
          child: Text(
            title,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: _titleStyle(),
          ),
        ),
      ),
    );
  }
}

/// The editing state: the same words in the same place, now typed into.
///
/// Sized by its own text rather than by the space available, so the field opens
/// exactly as wide as the name it holds and the "…" beside it doesn't jump
/// across the bar. It grows as you type, up to whatever room the top bar has —
/// which is also what lets a name the label had to cut short be read in full
/// while it is being edited.
class _TitleField extends StatelessWidget {
  const _TitleField({
    required this.controller,
    required this.focusNode,
    required this.onSubmit,
    required this.onCancel,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSubmit;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: _fieldMinWidth),
      child: IntrinsicWidth(
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): onCancel,
          },
          child: _TitleBox(
            editing: true,
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              autofocus: true,
              maxLines: 1,
              textInputAction: TextInputAction.done,
              cursorColor: AppPalette.accentOnSurface,
              cursorWidth: 1.5,
              style: _titleStyle(),
              onSubmitted: (_) => onSubmit(),
              // A click elsewhere in the window ends the edit the way clicking
              // past a rename dialog's field would — by keeping what's there,
              // not by throwing it away.
              onTapOutside: (_) => onSubmit(),
              // Collapsed, with the well drawn by [_TitleBox] instead:
              // Material's own decoration carries a minimum height and padding
              // the label can't match, which is what opened the field taller
              // and wider than the title it replaced.
              decoration: const InputDecoration.collapsed(hintText: ''),
            ),
          ),
        ),
      ),
    );
  }
}

/// The one box both states sit in: same padding, same rim thickness, same
/// height. Only the fill and the rim's colour change, so opening the field
/// lights a well behind the title instead of moving it.
///
/// The rim stays even while it is invisible — a border that appears only on
/// edit adds its 1px to the box and shunts the words along with it.
class _TitleBox extends StatelessWidget {
  const _TitleBox({required this.editing, required this.child});

  final bool editing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: _hPad, vertical: _vPad),
      decoration: BoxDecoration(
        color: editing ? AppPalette.cardBg : Colors.transparent,
        borderRadius: BorderRadius.circular(_boxRadius),
        border: Border.all(
          color: editing ? AppPalette.accentOnSurface : Colors.transparent,
        ),
      ),
      child: child,
    );
  }
}
