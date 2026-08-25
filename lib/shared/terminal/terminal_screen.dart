import 'dart:async';

import 'package:flutter/gestures.dart' show PointerScrollEvent, kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:xterm/xterm.dart';

import '../theme/app_theme.dart';
import '../widgets/app_menu_row.dart';
import '../widgets/labeled_field.dart';
import '../widgets/soft_action_button.dart';
import 'terminal_metrics.dart';
import 'terminal_ime_input.dart';
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
    this.metrics = TerminalMetrics.panel,
  });

  final TerminalSession session;

  /// How the screen is set — text size, and how wide it may grow. A Terminal tab
  /// takes the default; a chat that *is* a CLI passes [TerminalMetrics.agent],
  /// which stops at the width the program was drawn for.
  final TerminalMetrics metrics;

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
            metrics: metrics,
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
    required this.metrics,
  });

  final TerminalSession session;
  final bool focused;
  final ValueChanged<String>? onAddToChat;
  final TerminalMetrics metrics;

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

  /// Text an input method has finished with, on its way to the program — and,
  /// only if the screen was scrolled up, the view back to the bottom with it.
  ///
  /// `xterm` does the same for every key it handles itself, and typing into a
  /// screen scrolled up puts the characters somewhere the user can't see them.
  /// **Guarded, because this runs on every keystroke:** `jumpTo` ends the
  /// current scroll activity and starts another whether or not the offset
  /// moves, and the offset almost never moves — `RenderTerminal` already
  /// corrects to the bottom in `performLayout` for a screen that was there.
  void _typed(String text) {
    widget.session.terminal.textInput(text);
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.pixels >= position.maxScrollExtent) return;
    position.jumpTo(position.maxScrollExtent);
  }

  /// The viewport `TerminalView` scrolls, held here rather than left to it.
  ///
  /// The margins beside a clamped screen have to move the *same* scrollback the
  /// screen does, and there is no other way to reach it — see [_ScrollSpill].
  final _scroll = ScrollController();

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
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final session = widget.session;
    final canAdd = widget.onAddToChat != null;
    final theme = terminalPalette();
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
        child: _Clamped(
          metrics: widget.metrics,
          background: theme.background,
          session: session,
          scroll: _scroll,
          child: ImeTerminalInput(
            focusNode: _focus,
            onInput: _typed,
            // No scrollbar over a terminal. `xterm` draws its screen inside a
            // plain [Scrollable], and a `Scrollable` takes its chrome from the
            // ambient [ScrollBehavior] — so Material's desktop scrollbar was
            // sliding in over the right-hand column of the program's own output,
            // uninvited and unstyled by anything in the design system.
            //
            // It also made two agents look like different features. A CLI on the
            // alt screen has no scrollback, so its scroll extent is zero and the
            // bar never paints: Claude Code showed none, Codex — on the normal
            // buffer, with history behind it — showed one. Same terminal, same
            // pane, two answers.
            //
            // `copyWith` rather than a hand-rolled behaviour: the drag devices,
            // the physics and the overscroll are the platform's and stay so.
            // Scrolling is untouched — the wheel reaches the same
            // [ScrollController] it always did, and [_ScrollSpill] still feeds
            // it from the margins.
            builder: (context, onKeyEvent) => ScrollConfiguration(
              behavior: ScrollConfiguration.of(
                context,
              ).copyWith(scrollbars: false),
              child: TerminalView(
                session.terminal,
                controller: session.controller,
                scrollController: _scroll,
                simulateScroll: widget.metrics.simulateScroll,
                focusNode: _focus,
                theme: theme,
                // The text half of the keyboard is [ImeTerminalInput]'s, not
                // xterm's: its own can only append, so Vietnamese Telex — which
                // rewrites the letter it just typed — came out doubled. The keys
                // that are not text stay here, and this is how they get here
                // first.
                onKeyEvent: onKeyEvent,
                hardwareKeyboardOnly: true,
                // The app's own code face, at the size and on the line the metrics
                // set — so a path in a Terminal tab is the same width as the same
                // path in a chat message, and a CLI drawing a TUI gets the leading
                // a terminal app would have given it.
                textStyle: widget.metrics.style,
                padding: widget.metrics.padding,
                onSecondaryTapDown: (details, _) =>
                    unawaited(_secondaryTap(details.localPosition)),
              ),
            ),
          ),
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

/// Holds the screen to the width its metrics allow, and paints the terminal's
/// own background over whatever is left.
///
/// The strip either side is the *same* colour as the screen, deliberately: the
/// point is a terminal with a generous margin, not a terminal sitting on a slab.
/// Without the paint it would be the pane's background instead, and the two
/// differ (`windowBg` is the page, and a chat pane is not always on it).
///
/// **The strips also take the wheel** ([_ScrollSpill]). They are not part of
/// `TerminalView`, so a scroll landing on one reached nothing at all — and at
/// this width they are three hundred pixels of dead margin either side of the
/// text, which is exactly where a hand rests. That read as "the terminal
/// doesn't scroll".
class _Clamped extends StatelessWidget {
  const _Clamped({
    required this.metrics,
    required this.background,
    required this.session,
    required this.scroll,
    required this.child,
  });

  final TerminalMetrics metrics;
  final Color background;
  final TerminalSession session;
  final ScrollController scroll;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (metrics.maxColumns == null) return child;
    return ColoredBox(
      color: background,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = metrics.screenWidth(constraints.maxWidth);
          final spill = (constraints.maxWidth - width) / 2;
          return Row(
            children: [
              if (spill > 0)
                _ScrollSpill(
                  session: session,
                  metrics: metrics,
                  scroll: scroll,
                  width: spill,
                ),
              // Sized rather than constrained: `TerminalView` divides the box it
              // is given by the cell to decide how many columns the program has,
              // so the box has to be an exact width and the full height — a
              // loose constraint would let it shrink-wrap and take the column
              // count with it.
              SizedBox(
                width: width,
                height: constraints.maxHeight,
                child: child,
              ),
              if (spill > 0)
                _ScrollSpill(
                  session: session,
                  metrics: metrics,
                  scroll: scroll,
                  width: spill,
                ),
            ],
          );
        },
      ),
    );
  }
}

/// One of the margins beside a clamped screen: it draws nothing, and turns a
/// scroll into the wheel report the program is waiting for.
///
/// **Only when the program asked for the mouse** (`mouseMode.reportScroll`),
/// which the agent CLIs do — they take the whole screen and scroll their own
/// transcript, so the wheel is theirs and there is no scrollback here to move
/// instead. When they haven't asked, this does nothing rather than guessing:
/// synthesising arrow keys into a program that reads them as history is worse
/// than a margin that ignores a gesture.
///
/// The cell handed over is the middle of the screen, not the pointer: the
/// pointer is *outside* the terminal, so it has no cell — and the program only
/// needs to be told the wheel turned somewhere over its transcript.
class _ScrollSpill extends StatefulWidget {
  const _ScrollSpill({
    required this.session,
    required this.metrics,
    required this.scroll,
    required this.width,
  });

  final TerminalSession session;
  final TerminalMetrics metrics;
  final ScrollController scroll;
  final double width;

  @override
  State<_ScrollSpill> createState() => _ScrollSpillState();
}

class _ScrollSpillState extends State<_ScrollSpill> {
  /// Pan distance a trackpad has travelled since the last line was sent.
  ///
  /// A trackpad reports a continuous stream of small deltas rather than notches,
  /// so the remainder has to be kept: rounding each one on its own is how a slow
  /// two-finger drag scrolls nothing at all.
  double _panned = 0;

  void _scroll(double dy) {
    final terminal = widget.session.terminal;
    // The program asked for the mouse, so the wheel is its own — it keeps the
    // transcript and scrolls it itself. The cell handed over is the middle of
    // the screen, not the pointer: the pointer is *outside* the terminal, so it
    // has no cell, and the program only needs to know the wheel turned over its
    // transcript.
    if (terminal.mouseMode.reportScroll) {
      final lines = dy ~/ widget.metrics.lineBox();
      if (lines == 0) return;
      final at = CellOffset(terminal.viewWidth ~/ 2, terminal.viewHeight ~/ 2);
      for (var i = 0; i < lines.abs(); i++) {
        terminal.mouseInput(
          lines < 0
              ? TerminalMouseButton.wheelUp
              : TerminalMouseButton.wheelDown,
          TerminalMouseButtonState.down,
          at,
        );
      }
      return;
    }
    // It didn't, so what scrolls is the scrollback the emulator kept — the same
    // viewport the screen itself scrolls, which is the whole reason the
    // controller is passed down here. Codex spends most of its life this way.
    if (!widget.scroll.hasClients) return;
    final position = widget.scroll.position;
    final target = (position.pixels + dy).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target == position.pixels) return;
    position.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) => Listener(
    // The margin draws nothing, so without this it isn't in the hit test at all
    // and every gesture over it lands on whatever is behind — which is how it
    // came to swallow the wheel in the first place.
    behavior: HitTestBehavior.opaque,
    onPointerSignal: (event) {
      if (event is PointerScrollEvent) _scroll(event.scrollDelta.dy);
    },
    onPointerPanZoomStart: (_) => _panned = 0,
    onPointerPanZoomUpdate: (event) {
      // Pan is where the *content* went, so it points the opposite way to a
      // wheel: dragging two fingers down moves the transcript down, which is
      // scrolling up.
      final moved = -event.panDelta.dy;
      _panned += moved;
      final line = widget.metrics.lineBox();
      if (_panned.abs() < line) return;
      _scroll(_panned);
      _panned %= line;
    },
    onPointerPanZoomEnd: (_) => _panned = 0,
    child: SizedBox(width: widget.width, height: double.infinity),
  );
}
