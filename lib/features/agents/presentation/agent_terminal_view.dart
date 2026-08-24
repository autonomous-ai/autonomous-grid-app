import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/copy/setup_hints.dart';
import '../../../shared/terminal/terminal_palette.dart';
import '../../../shared/terminal/terminal_session.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/soft_action_button.dart';
import '../logic/agent_catalog.dart';
import '../logic/agent_terminals_controller.dart';

/// A chat whose agent runs in its own CLI, shown as that CLI.
///
/// This is the agent's real interface, not a picture of one: what is on screen
/// is the program's own output, and what the user types goes to it as
/// keystrokes. So the permission prompt is the CLI's, answered the way the CLI
/// asks; a message typed while it is working reaches the turn that is running;
/// and the conversation belongs to the session rather than to a transcript this
/// app replays. Nothing in between reads a byte of it.
///
/// The session outlives this widget — it belongs to the chat (see
/// [agentTerminalsProvider]) — so switching chats and coming back finds the
/// agent where it was left, still working if it was working.
class AgentTerminalView extends ConsumerStatefulWidget {
  const AgentTerminalView({
    super.key,
    required this.chatId,
    required this.tool,
    required this.model,
    required this.workdir,
    required this.approval,
    required this.network,
  });

  final String chatId;
  final AgentTool tool;
  final String model;

  /// The folder the CLI opens in — the chat's project, or the app's workspace.
  final String workdir;

  /// What the chat lets the agent do unattended. It reaches the CLI as its own
  /// flags, so the picker means here exactly what it means in a terminal.
  final AgentApprovalMode approval;

  final NetworkCredential network;

  @override
  ConsumerState<AgentTerminalView> createState() => _AgentTerminalViewState();
}

class _AgentTerminalViewState extends ConsumerState<AgentTerminalView> {
  /// Held rather than left to `autofocus`, which fires once at mount: a chat is
  /// opened and closed over and over on the same session, and each opening has
  /// to be typeable straight away.
  final _focus = FocusNode(debugLabel: 'agent-terminal');

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(AgentTerminalView old) {
    super.didUpdateWidget(old);
    // A different chat in the same slot needs its own session; the same chat
    // keeps the one it has, model and mode included — those reach the CLI when
    // it starts, and a running agent cannot be re-flagged mid-session any more
    // than one in a terminal could.
    if (old.chatId != widget.chatId) _open();
  }

  /// Opening is asynchronous and must not run inside `build` (§2), so it is
  /// asked for after the frame the view first appears in.
  void _open() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(agentTerminalsProvider.notifier)
          .ensure(
            chatId: widget.chatId,
            tool: widget.tool,
            model: widget.model,
            workdir: widget.workdir,
            approval: widget.approval,
            network: widget.network,
          );
      _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final session = ref.watch(
      agentTerminalsProvider.select((s) => s[widget.chatId]),
    );
    if (session == null) {
      // "Starting…" for an agent that isn't on this computer would spin for
      // ever, which is the shape of a hung app rather than of a missing one.
      return _Opening(
        installed: ref.watch(agentExecutableProvider(widget.tool)) != null,
        tool: widget.tool,
      );
    }

    return Column(
      children: [
        Expanded(
          child: TerminalView(
            session.terminal,
            controller: session.controller,
            focusNode: _focus,
            theme: terminalPalette(),
            // The app's own code face, at the size the rest of the app sets code
            // in — a path in the agent's output and the same path in a chat
            // message are then the same width on screen.
            textStyle: TerminalStyle(
              fontSize: 12.5,
              fontFamily: AppFont.mono,
              fontFamilyFallback: AppFont.monoFallback,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
        ),
        if (_endedMessage(session.shell) case final message?)
          _EndedBar(message: message, chatId: widget.chatId),
      ],
    );
  }

  /// The line for a session that is no longer running, or null while it is.
  ///
  /// A dead terminal that says nothing is the worst version of this: the user
  /// types, nothing happens, and there is no telling that from the app being
  /// stuck.
  String? _endedMessage(ShellState shell) => switch (shell) {
    ShellRunning() || ShellIdle() => null,
    ShellFailed(:final message) => message,
    ShellExited(:final code) =>
      code == 0
          ? '${widget.tool.name} closed.'
          : '${widget.tool.name} closed unexpectedly (exit code $code).',
  };
}

/// The moment between opening a chat and its CLI drawing its first frame — the
/// grid is being prepared and the process spawned — or the plain statement that
/// there is no CLI here to start.
class _Opening extends StatelessWidget {
  const _Opening({required this.installed, required this.tool});

  final bool installed;
  final AgentTool tool;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      installed ? 'Starting ${tool.name}…' : notSetUpToMessage('answer chats'),
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: 12.5, color: AppPalette.textSecondary),
    ),
  );
}

/// The strip under a session that has ended, with the one thing worth doing.
class _EndedBar extends ConsumerWidget {
  const _EndedBar({required this.message, required this.chatId});

  final String message;
  final String chatId;

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
                  ref.read(agentTerminalsProvider.notifier).restart(chatId),
            ),
          ],
        ),
      ),
    );
  }
}
