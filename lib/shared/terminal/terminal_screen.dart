import 'dart:async';

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:xterm/xterm.dart';

import '../theme/app_theme.dart';
import '../widgets/app_menu_row.dart';
import '../widgets/labeled_field.dart';
import '../widgets/soft_action_button.dart';
import 'terminal_palette.dart';
import 'terminal_session.dart';
import 'terminal_text.dart';

/// The one line a session that is no longer running shows, or null while it is
/// still running.
///
/// [subject] is what closed, in the words of the screen asking — "This terminal"
/// in a Terminal tab, the agent's own name in a chat that runs one. The rest of
/// the sentence is the same everywhere, because a shell that ended is the same
/// event wherever it is shown (§5).
///
/// A dead terminal that says nothing is the worst version of this: the user
/// types, nothing happens, and there is no telling that from the app being
/// stuck.
String? shellEndedMessage(ShellState shell, {required String subject}) =>
    switch (shell) {
      ShellIdle() || ShellRunning() => null,
      ShellFailed(:final message) => message,
      ShellExited(:final code) =>
        code == 0
            ? '$subject closed.'
            : '$subject closed unexpectedly (exit code $code).',
    };

/// One terminal on screen: its output, and — once its shell has ended — the
/// line saying so.
///
/// Shared by the Terminal tab and by a chat whose agent runs in its own CLI:
/// both are a pty on screen, so both get the same selection menu, the same
/// right-click paste and the same ended bar. The two things that genuinely
/// differ are what to call the program that closed ([subject]) and who knows
/// how to start it again ([onRestart]).
class TerminalScreen extends StatelessWidget {
  const TerminalScreen({
    super.key,
    required this.session,
    required this.focused,
    required this.subject,
    required this.onRestart,
    this.onAddToChat,
  });

  final TerminalSession session;

  /// What to call the program in the line shown once it has ended — see
  /// [shellEndedMessage].
  final String subject;

  /// Opens a fresh program in this terminal, keeping the scrollback above it.
  final VoidCallback onRestart;

  /// A run of output picked out of the screen, on its way to the conversation.
  /// Null when there is no chat to put it in — including a chat that *is* this
  /// terminal — and then the menu offers only what the clipboard would.
  final ValueChanged<String>? onAddToChat;

  /// Whether the panel holding this is actually open.
  ///
  /// The panels stay in the tree while closed so they can slide both ways, and
  /// a terminal that keeps the keyboard while hidden is the worst outcome
  /// available: the user types into the chat and the characters go to a shell
  /// they can't see.
  final bool focused;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: _Screen(
            session: session,
            focused: focused,
            onAddToChat: onAddToChat,
          ),
        ),
        if (shellEndedMessage(session.shell, subject: subject)
            case final message?)
          _EndedBar(message: message, onRestart: onRestart),
      ],
    );
  }
}

class _Screen extends StatefulWidget {
  const _Screen({
    required this.session,
    required this.focused,
    required this.onAddToChat,
  });

  final TerminalSession session;
  final bool focused;
  final ValueChanged<String>? onAddToChat;

  @override
  State<_Screen> createState() => _ScreenState();
}

/// How far the pointer must travel before a press counts as picking text out.
///
/// The same number the file viewer's selection menu uses: a click *inside* a
/// selection is how you dismiss it, and a click that landed a pixel off centre
/// must not be read as a fresh drag.
const double _dragSlop = 6;

class _ScreenState extends State<_Screen> {
  final _menu = MenuController();

  /// Where the primary button went down, so a release can tell a drag from a
  /// click. Null when the press was some other button.
  Offset? _pressed;

  /// What was highlighted when the menu went up.
  ///
  /// Read then rather than when a row is tapped: the rows act on the selection
  /// the user was looking at when they opened it, and anything that clears the
  /// highlight in between would leave the menu standing over nothing.
  String? _offered;

  /// The text of the current selection, or null when there isn't one worth
  /// offering.
  String? get _selectedText {
    final selection = widget.session.controller.selection;
    if (selection == null) return null;
    final text = selectionText(widget.session.terminal.buffer, selection);
    return text.trim().isEmpty ? null : text;
  }

  /// Raise the menu over [at] if there is a selection to act on.
  ///
  /// After the frame, because a drag finalises its selection on release: asking
  /// in the same event reads the *previous* answer.
  void _offerMenu(Offset at) {
    // Read now *and* after the frame, and keep whichever answered. A drag only
    // finalises its selection on release, so now is too early for one; a
    // right-click can clear the selection on its way through xterm, so after is
    // too late for the other.
    final now = _selectedText;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final text = _selectedText ?? now;
      if (!mounted || text == null || _menu.isOpen) return;
      _offered = text;
      // Just below the pointer, so the menu doesn't land on the last of what
      // was selected.
      _menu.open(position: at + const Offset(4, 8));
    });
  }

  void _add() {
    final text = _offered;
    _menu.close();
    // The highlight stays so the user can see what they just sent; only the
    // menu goes.
    if (text != null) widget.onAddToChat?.call(text);
  }

  void _copy() {
    final text = _offered;
    _menu.close();
    if (text != null) Clipboard.setData(ClipboardData(text: text));
  }

  /// Everything the buffer holds, scrollback included — what select-all means in
  /// a terminal, where the interesting part is usually above the fold.
  void _selectAll() {
    _menu.close();
    final buffer = widget.session.terminal.buffer;
    final lines = buffer.height;
    if (lines == 0) return;
    widget.session.controller.setSelection(
      buffer.createAnchor(0, 0),
      buffer.createAnchor(widget.session.terminal.viewWidth - 1, lines - 1),
    );
  }

  /// Right-click with nothing selected is still paste — the convention every
  /// terminal on Windows and Linux follows, and the only way to paste here for
  /// anyone who doesn't reach for ⌘V. With a selection, the menu takes over: it
  /// used to copy silently, which is a menu's job done without a menu.
  Future<void> _secondaryTap(Offset at) async {
    if (_selectedText != null) {
      _offerMenu(at);
      return;
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null) widget.session.terminal.paste(text);
  }

  /// Held here rather than left to `autofocus`, which fires once at mount: a
  /// panel is opened and closed over and over on the same terminal, and each
  /// opening has to be typeable straight away.
  final _focus = FocusNode(debugLabel: 'terminal');

  @override
  void initState() {
    super.initState();
    if (widget.focused) _focus.requestFocus();
  }

  @override
  void didUpdateWidget(_Screen old) {
    super.didUpdateWidget(old);
    // Also when the same slot is handed a different terminal — switching chats
    // swaps the session under a view that never stopped being [focused], and a
    // chat the user just opened has to be typeable straight away.
    if (widget.focused && (!old.focused || old.session != widget.session)) {
      _focus.requestFocus();
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final session = widget.session;
    final canAdd = widget.onAddToChat != null;
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
              // The same three rows, in the same order and the same words, as
              // the menu a selection raises in the file viewer and in a diff.
              // One gesture, one answer, wherever the user is reading (§5).
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
      child: Listener(
        // A press anywhere puts the last menu away — including the press that
        // starts the next selection, which would otherwise leave two on screen.
        onPointerDown: (event) {
          if (_menu.isOpen) _menu.close();
          _pressed = switch (event.buttons) {
            kPrimaryButton => event.localPosition,
            _ => null,
          };
        },
        // Only a drag. A click that never travelled is how a selection is thrown
        // away, not how you ask about one — popping the menu there would put it
        // over a highlight the user was in the middle of dismissing.
        onPointerUp: (event) {
          final from = _pressed;
          _pressed = null;
          if (from == null) return;
          if ((event.localPosition - from).distance < _dragSlop) return;
          _offerMenu(event.localPosition);
        },
        child: TerminalView(
          session.terminal,
          controller: session.controller,
          focusNode: _focus,
          theme: terminalPalette(),
          // The app's own code face, at the size the rest of the app sets code
          // in, so a path in the terminal and the same path in a chat message
          // are the same width on screen.
          textStyle: TerminalStyle(
            fontSize: 12.5,
            fontFamily: AppFont.mono,
            fontFamilyFallback: AppFont.monoFallback,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          onSecondaryTapDown: (details, _) =>
              unawaited(_secondaryTap(details.localPosition)),
        ),
      ),
    );
  }
}

/// The strip under a terminal whose program has ended — because it exited, or
/// because it never opened — saying what happened and offering the one thing
/// worth doing.
class _EndedBar extends StatelessWidget {
  const _EndedBar({required this.message, required this.onRestart});

  final String message;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppPalette.panelBg,
        border: Border(top: BorderSide(color: AppPalette.divider)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  fontSize: 12.5,
                  color: AppPalette.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            SoftActionButton(
              leading: const Icon(Icons.refresh_rounded, size: 15),
              label: 'Start again',
              compact: true,
              onPressed: onRestart,
            ),
          ],
        ),
      ),
    );
  }
}
