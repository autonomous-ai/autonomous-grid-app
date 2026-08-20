import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../logic/chat_sessions_controller.dart';

/// The widest the field ever grows. The title sits beside its "…" like a label
/// on a tab, and a field that ran to the window's edge would turn the top bar
/// into a form.
const _fieldMaxWidth = 360.0;

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
    _controller.text = widget.title;
    // Selected, not just placed: the usual rename replaces the whole
    // auto-generated name, and leaving the caret at the end makes that a
    // select-all first.
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
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
        child: Text(
          title,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: AppPalette.textPrimary,
            fontSize: 13.5,
            fontWeight: AppFont.medium,
          ),
        ),
      ),
    );
  }
}

/// The editing state: the same words, now typed into.
///
/// Sized and weighted like the label it replaces so the title doesn't jump when
/// the field opens — only the soft well behind it appears.
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
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppControl.radius),
      borderSide: BorderSide(color: AppGlass.hair),
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _fieldMaxWidth),
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): onCancel},
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          autofocus: true,
          maxLines: 1,
          textInputAction: TextInputAction.done,
          cursorColor: AppPalette.accentOnSurface,
          style: TextStyle(
            color: AppPalette.textPrimary,
            fontSize: 13.5,
            fontWeight: AppFont.medium,
            height: 1.2,
          ),
          onSubmitted: (_) => onSubmit(),
          // A click elsewhere in the window ends the edit the way clicking past
          // a rename dialog's field would — by keeping what's there, not by
          // throwing it away.
          onTapOutside: (_) => onSubmit(),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: AppPalette.cardBg,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 6,
            ),
            border: border,
            enabledBorder: border,
            focusedBorder: border.copyWith(
              borderSide: BorderSide(color: AppPalette.accentOnSurface),
            ),
          ),
        ),
      ),
    );
  }
}
