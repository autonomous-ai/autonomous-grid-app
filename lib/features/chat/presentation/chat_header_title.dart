import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../logic/chat_sessions_controller.dart';
import '../logic/chat_title.dart';

/// The box both states wear — see [_TitleBox]. Small numbers, but they have to
/// be the *same* numbers on the label and on the field, or opening the field
/// nudges the title sideways.
///
/// 6/4 rather than the 5/3 these were: the box used to carry a 1px rim it no
/// longer draws, and the padding takes that pixel back so the title sits where
/// it always did — 9px from the icon, 24.2px tall, in every state.
const _hPad = 6.0;
const _vPad = 4.0;

/// On the ladder (8 = inset & button), where the 7 it was is on nothing. The box
/// is 24px tall, so it reads as an inset well rather than as a field.
const _boxRadius = 8.0;

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
    if (old.id == widget.id) return;
    // Switching conversations mid-edit is an unfocus like any other, so what
    // was typed is kept — on the chat that was being named, never stamped onto
    // the one that just arrived. Usually the switch has already unfocused the
    // field (clicking a sidebar row does), and this catches the ways it hasn't:
    // a keyboard shortcut, a chat opened from elsewhere in the app.
    //
    // Deferred a frame: this runs inside the parent's build, and writing to a
    // provider there is the one thing Riverpod won't have (§2).
    final name = _controller.text.trim();
    final id = old.id;
    final was = old.title;
    _editing = false;
    if (name.isEmpty || name == was) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(chatSessionsProvider.notifier).renameConversation(id, name);
    });
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
    // A caret at the end, not a select-all over the whole name.
    //
    // The select-all this used to do is why the field opened with no caret at
    // all: a caret is only drawn for a *collapsed* selection, so covering the
    // title in a selection band hid the one mark that says "type here". It also
    // put the rename one keystroke from destroying the name — which is the
    // wrong default for a title people mostly *amend*. Whoever does want to
    // replace the lot still has ⌘A, and now they can see where they are first.
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
    setState(() => _editing = true);
  }

  /// Keeps what was typed — the only way out of the field other than Escape.
  ///
  /// Every unfocus routes here: Enter, a click anywhere else in the window
  /// ([_TitleField]'s `onTapOutside`), Tab, and the app being sent to the back
  /// mid-edit (the [_focus] listener). There is deliberately no confirm step; a
  /// rename people can see the result of is one they can simply do again.
  ///
  /// A blank name is the one value a chat can't wear, so it falls back to the
  /// title that was already there rather than clearing it.
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
///
/// No hover fill. It had one for a while — a whisper of a well to say the title
/// was a control at all — and it had to go: the pointer is still sitting on the
/// title at the moment the rename is committed, so finishing an edit left the
/// name in a grey box that read as "still editing". A cue that only appears
/// when the cursor is elsewhere is a cue nobody sees; one that lingers exactly
/// when the edit ends is worse than none. The tooltip carries the affordance
/// instead.
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
          fill: Colors.transparent,
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
            // The one surface on screen that has to carry a *recessed* reading
            // on a bar with no fill of its own. `cardBg` — what this used to
            // use — measures 1.065:1 against the dark page behind the strip and
            // is simply not there, which is why the box needed an accent rim to
            // be seen at all. This overlay rides whatever the bar sits on:
            // 1.345:1 dark, 1.171:1 light, a clear step above the hover well.
            fill: AppSurface.recessHover,
            // A grey rim, not an accent one. Focus still has to be visible,
            // but an indigo hairline round a title in a quiet strip reads as an
            // alert rather than as "you are typing here" — `accentOnSurface`
            // measures 5.75:1 against the page, which is *louder than the title
            // it surrounds*. This is the same soft grey the composer uses to
            // hold its edge, and it lands where the eye expects a rim: 2.38:1
            // against the page in dark, 1.78:1 in light. The well behind the
            // text is what says "focused"; the rim only draws the shape.
            ring: AppGlass.lift,
            child: Theme(
              // The app's field theme is built for a form: `isDense`, a fill, a
              // rim, and — the one that broke this — a 36px `minHeight` from
              // [AppControl.heightField]. `InputDecoration.collapsed` cannot
              // undo that: it sets `contentPadding` and `border`, but leaves
              // `constraints` null, so `applyDefaults` hands the field the
              // form's floor and the box opened **44px tall against a 24px
              // label**. Stripped to a bare theme, the same way the document
              // editor strips it — see `office_editor_view.dart`. Measured
              // after: label 24.0, field 24.0, and the text starts at the same
              // x in both.
              data: Theme.of(context).copyWith(
                inputDecorationTheme: const InputDecorationTheme(),
                // Material's default selection is `primary` at 40%, which over
                // a dark well paints an almost-opaque indigo slab: drag-select
                // a title and the words disappear into one blue block. At 22%
                // — the same wash the document editor uses — it is a tint the
                // words still sit *in*, with the ink at 10.4:1.
                textSelectionTheme: TextSelectionThemeData(
                  cursorColor: AppPalette.textPrimary,
                  selectionColor: AppPalette.accent.withValues(alpha: 0.22),
                  selectionHandleColor: AppPalette.accent,
                ),
              ),
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                autofocus: true,
                maxLines: 1,
                textInputAction: TextInputAction.done,
                // The caret is the title's own ink, not the accent: at 13.5pt
                // in a 24px box an indigo bar is the brightest thing in the
                // strip, and it is meant to mark a position, not announce one.
                cursorColor: AppPalette.textPrimary,
                cursorWidth: 1.5,
                cursorRadius: const Radius.circular(1),
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
      ),
    );
  }
}

/// The one box both states sit in: same padding, same height, only the fill and
/// the ring change. Opening the field lights a well behind the title instead of
/// moving it; closing it puts the box back to bare transparent, so the name
/// looks exactly as it did before the rename.
///
/// **The ring is a shadow, not a border**, and that is the whole trick. A real
/// `Border` adds its 1px to the box, so a ring that appears only on focus makes
/// the title jump the moment it is clicked — the same class of bug as the 36px
/// field floor. A shadow with `spreadRadius: 1` and no blur paints the identical
/// hairline *outside* the box's own 24.0px, so label, hover and field all
/// measure the same.
class _TitleBox extends StatelessWidget {
  const _TitleBox({required this.fill, this.ring, required this.child});

  final Color fill;

  /// The focus hairline, or null at rest. Only the field passes one — it is the
  /// one state that has keyboard focus to report.
  final Color? ring;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return AnimatedContainer(
      // Fast enough to feel like the same box changing state rather than a
      // second box arriving.
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: _hPad, vertical: _vPad),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(_boxRadius),
        boxShadow: ring == null
            ? null
            : [BoxShadow(color: ring!, spreadRadius: 1)],
      ),
      child: child,
    );
  }
}
