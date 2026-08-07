import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/soft_action_button.dart';
import '../logic/terminal_session.dart';
import '../logic/terminal_sessions_controller.dart';
import 'terminal_palette.dart';

/// One terminal on screen: its output, and — once its shell has ended — the
/// line saying so.
class TerminalScreen extends StatelessWidget {
  const TerminalScreen({
    super.key,
    required this.session,
    required this.focused,
  });

  final TerminalSession session;

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
          child: _Screen(session: session, focused: focused),
        ),
        switch (session.shell) {
          ShellIdle() || ShellRunning() => const SizedBox.shrink(),
          ShellExited() => _EndedBar(
            message: 'This terminal has closed.',
            id: session.id,
          ),
          ShellFailed(:final message) => _EndedBar(
            message: message,
            id: session.id,
          ),
        },
      ],
    );
  }
}

class _Screen extends StatefulWidget {
  const _Screen({required this.session, required this.focused});

  final TerminalSession session;
  final bool focused;

  @override
  State<_Screen> createState() => _ScreenState();
}

class _ScreenState extends State<_Screen> {
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
    if (widget.focused && !old.focused) _focus.requestFocus();
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
    return TerminalView(
      session.terminal,
      controller: session.controller,
      focusNode: _focus,
      theme: terminalPalette(),
      // The app's own code face, at the size the rest of the app sets code in,
      // so a path in the terminal and the same path in a chat message are the
      // same width on screen.
      textStyle: TerminalStyle(
        fontSize: 12.5,
        fontFamily: AppFont.mono,
        fontFamilyFallback: AppFont.monoFallback,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      // Right-click is copy-when-something-is-selected, paste otherwise — the
      // convention every terminal on Windows and Linux follows, and harmless on
      // macOS where ⌘C/⌘V (xterm's own defaults) are what most people reach for.
      onSecondaryTapDown: (details, offset) => _copyOrPaste(session),
    );
  }
}

Future<void> _copyOrPaste(TerminalSession session) async {
  final selection = session.controller.selection;
  if (selection != null) {
    final text = session.terminal.buffer.getText(selection);
    session.controller.clearSelection();
    await Clipboard.setData(ClipboardData(text: text));
    return;
  }
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  final text = data?.text;
  if (text != null) session.terminal.paste(text);
}

/// The strip under a terminal whose shell has ended — because it exited, or
/// because it never opened.
///
/// A dead terminal that says nothing is the worst version of this: the user
/// types, nothing happens, and there is no way to tell that from the app being
/// stuck. So it says what happened and offers the one thing worth doing.
class _EndedBar extends ConsumerWidget {
  const _EndedBar({required this.message, required this.id});

  final String message;
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
              onPressed: () =>
                  ref.read(terminalSessionsProvider.notifier).restart(id),
            ),
          ],
        ),
      ),
    );
  }
}
