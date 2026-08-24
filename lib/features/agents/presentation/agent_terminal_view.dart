import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/copy/setup_hints.dart';
import '../../../shared/terminal/terminal_screen.dart';
import '../../../shared/theme/app_theme.dart';
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
/// The screen itself is [TerminalScreen] — the same one a Terminal tab draws, so
/// selecting output, copying it and right-click-to-paste work here exactly as
/// they do there. What this widget adds is the one thing a chat knows and a tab
/// doesn't: which agent to start, and when.
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
    if (old.chatId != widget.chatId) return _open();
    // The model picker settles a frame or two after the chat opens, and a
    // session cannot start before it does — the model is the `--model` the CLI
    // runs on. So the first build with a model is also an opening.
    if (old.model.trim().isEmpty && widget.model.trim().isNotEmpty) _open();
  }

  /// Opening is asynchronous and must not run inside `build` (§2), so it is
  /// asked for after the frame the view first appears in. It is a no-op until
  /// the chat knows its model, and once a session exists.
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
    });
  }

  @override
  Widget build(BuildContext context) {
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

    return TerminalScreen(
      session: session,
      // The chat pane is only built while it is the pane on screen, and this
      // terminal is the whole of it — there is nothing else here to type into.
      focused: true,
      subject: widget.tool.name,
      onRestart: () =>
          ref.read(agentTerminalsProvider.notifier).restart(widget.chatId),
      // No "Add to Chat": this terminal *is* the chat, so the row would offer
      // to move a line from where it already is to where it already is.
    );
  }
}

/// The moment between opening a chat and its CLI drawing its first frame — the
/// grid is being prepared and the process spawned — or the plain statement that
/// there is no CLI here to start.
class _Opening extends StatelessWidget {
  const _Opening({required this.installed, required this.tool});

  final bool installed;
  final AgentTool tool;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Center(
      child: Text(
        installed
            ? 'Starting ${tool.name}…'
            : notSetUpToMessage('answer chats'),
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12.5, color: AppPalette.textSecondary),
      ),
    );
  }
}
