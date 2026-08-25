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

  /// What the chat lets the agent do unattended, as the flags its CLI starts
  /// with.
  ///
  /// The chat still holds this, but nothing under a terminal offers to change
  /// it: the running CLI shows its own gate and takes the answer from the
  /// keyboard (Claude Code cycles it on shift+tab), and a second control beside
  /// that one would be stale as soon as the real one was used. It reaches a new
  /// process on the next Restart.
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
    // Ask again whenever one of the three things a session is built from moves,
    // and let [AgentTerminalsController.ensure] decide what that means: a
    // different chat needs its own session, a different agent takes over this
    // one, and the same agent on a different model is left alone — the model is
    // the CLI's to change from here, on `/model`.
    //
    // The model still matters to *this* call, twice over. A session cannot
    // start before the picker has settled a frame or two after the chat opens,
    // because the model is the `--model` the CLI runs on; and switching agent
    // moves the model a frame later, which is the build that finally has a pair
    // `ensure` will start.
    if (old.chatId != widget.chatId ||
        old.tool != widget.tool ||
        old.model.trim() != widget.model.trim()) {
      _open();
    }
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
