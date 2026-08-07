import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/terminal_sessions_controller.dart';
import 'terminal_screen.dart';

/// A terminal session, in a panel tab: a real login shell, running in the folder
/// the conversation is about.
///
/// The only surface here with no toolbar of its own. Every other feature needs a
/// row to say where it is — a breadcrumb, an address — but a shell says so in
/// its own prompt, on every line, and a strip repeating it above would be the
/// same fact twice with the output pushed down to make room.
class TerminalPanelView extends ConsumerStatefulWidget {
  const TerminalPanelView({
    super.key,
    required this.tabId,
    required this.workdir,
    required this.showing,
  });

  /// The tab that owns this terminal — its shell dies with it.
  final String tabId;

  /// Where the shell starts. Read when the tab opens and not again: a running
  /// shell can't be moved, `cd` is the user's to type.
  final String workdir;

  /// Whether the panel holding this tab is open — see [TerminalScreen.focused].
  final bool showing;

  @override
  ConsumerState<TerminalPanelView> createState() => _TerminalPanelViewState();
}

class _TerminalPanelViewState extends ConsumerState<TerminalPanelView> {
  @override
  void initState() {
    super.initState();
    _openShell();
  }

  /// Also on update, not only on mount: a panel that reuses this element for
  /// another tab (no key, or a key that changed shape) would otherwise leave
  /// the new tab pointing at a shell that was never started — an empty screen
  /// where a terminal should be.
  @override
  void didUpdateWidget(TerminalPanelView old) {
    super.didUpdateWidget(old);
    if (widget.tabId != old.tabId) _openShell();
  }

  /// Post-frame, never straight from `build`: writing a provider while the
  /// tree is building throws.
  void _openShell() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(terminalSessionsProvider.notifier)
          .ensure(tabId: widget.tabId, workdir: widget.workdir);
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(terminalSessionsProvider)[widget.tabId];
    // One frame with nothing in it, between this tab being built and its shell
    // being spawned. An empty state here would flash "no terminal" at somebody
    // who just opened one.
    if (session == null) return const SizedBox.shrink();
    return TerminalScreen(session: session, focused: widget.showing);
  }
}
