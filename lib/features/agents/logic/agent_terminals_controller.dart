import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/terminal/terminal_session.dart';
import 'adapters/agent_grid_setup.dart';
import 'adapters/agent_terminal_command.dart';
import 'adapters/claude_tool.dart';
import 'adapters/codex_tool.dart';
import 'adapters/hermes_tool.dart';
import 'agent_catalog.dart';

/// The binary behind one agent, or null when it isn't installed on this machine.
///
/// One place to ask, so a caller that needs "the agent, whichever it is" doesn't
/// have to know the three provider names.
final agentExecutableProvider = Provider.family<String?, AgentTool>(
  (ref, tool) => switch (tool) {
    AgentTool.claude => ref.watch(claudePathProvider),
    AgentTool.codex => ref.watch(codexPathProvider),
    AgentTool.hermes => ref.watch(hermesPathProvider),
  },
);

/// The agent terminals the app has open, one per chat that runs its agent in
/// one.
@immutable
class AgentTerminalsState {
  AgentTerminalsState({Map<String, TerminalSession> sessions = const {}})
    : sessions = Map.unmodifiable(sessions);

  /// Keyed by conversation id.
  final Map<String, TerminalSession> sessions;

  /// The terminal for [chatId], or null before one has been opened.
  TerminalSession? operator [](String chatId) => sessions[chatId];
}

/// Every open agent terminal, keyed by the chat it belongs to.
///
/// **One long-lived CLI per chat, and the conversation lives inside it.** That
/// is the whole point of this lane: the user drives the agent's own interface,
/// so the session, its context, its permission prompts and its mid-turn input
/// are the agent's to keep rather than something this app reconstructs. Nothing
/// here parses a byte of what comes back — the pty carries it to an emulator and
/// the emulator draws it.
///
/// Not auto-disposed: switching to another chat must not kill the agent working
/// in this one. Sessions end when the chat is closed, or when the app is.
final agentTerminalsProvider =
    NotifierProvider<AgentTerminals, AgentTerminalsState>(AgentTerminals.new);

class AgentTerminals extends Notifier<AgentTerminalsState> {
  /// Held here rather than read back off [state]: the sessions are killed in
  /// `onDispose`, and Riverpod forbids touching `state` from a life-cycle
  /// callback.
  final Map<String, TerminalSession> _sessions = {};

  /// Chats whose session is being prepared right now.
  ///
  /// Opening one is asynchronous (the MCP config is written, the tools server is
  /// started), and the view calls [ensure] on every build — without this, two
  /// builds a frame apart would each get past the "already open?" check and
  /// spawn a second CLI on the same chat.
  final Set<String> _opening = {};

  @override
  AgentTerminalsState build() {
    ref.onDispose(_disposeAll);
    return _snapshot();
  }

  /// Opens the agent terminal for [chatId], or leaves the one already running
  /// there alone. Safe to call on every build of the chat's view.
  ///
  /// Silently does nothing for an agent that has no interactive CLI this app
  /// drives, or one that isn't installed: both are states the chat already has a
  /// screen for, and a terminal that flashes and dies is a worse way to say so.
  Future<void> ensure({
    required String chatId,
    required AgentTool tool,
    required String model,
    required String workdir,
    required AgentApprovalMode approval,
    required NetworkCredential network,
  }) async {
    if (!tool.runsInTerminal) return;
    // Nothing about a session can be built before the model is known: it is the
    // `--model` the CLI is started with, and it is every tier of the grid setup
    // the CLI answers from. The picker settles a frame or two after the chat
    // opens, and starting in that gap started Claude Code on `--model ""`,
    // which asked the grid for a model with no name and got back
    // `503 No providers available for this model`, ten times over.
    // [AgentTerminalView] asks again as soon as it has one.
    if (model.trim().isEmpty) return;
    if (_sessions.containsKey(chatId) || !_opening.add(chatId)) return;
    try {
      final executable = ref.read(agentExecutableProvider(tool));
      if (executable == null) return;

      final setup = await _setupFor(
        tool: tool,
        model: model,
        network: network,
        chatId: chatId,
      );
      // The chat was closed while its grid was being prepared.
      if (!ref.mounted) return;

      final session = TerminalSession(
        id: chatId,
        workdir: workdir,
        command: agentTerminalCommand(
          tool: tool,
          executable: executable,
          model: model,
          workdir: workdir,
          approval: approval,
          mcpConfigPath: setup.mcpConfig,
          config: setup.config,
        ),
        environment: setup.environment,
        onChanged: _publish,
      );
      _sessions[chatId] = session;
      session.start(onError: _logStartFailure);
      _publish();
    } finally {
      _opening.remove(chatId);
    }
  }

  /// Types [text] into the chat's agent and submits it — what the composer's
  /// Send does for a chat that runs in a terminal.
  ///
  /// The user can type into the terminal directly too, and that is the same
  /// keystrokes down the same pipe: this exists so Send keeps working, not
  /// because the app needs a channel of its own.
  Future<void> type(String chatId, String text) async =>
      _sessions[chatId]?.type(text);

  /// Puts [text] at the CLI's prompt without submitting it — a dropped file's
  /// path, landing where the user is still writing the rest of the line.
  ///
  /// False when this chat has no terminal running, so a caller can fall back to
  /// what it would have done otherwise.
  bool insert(String chatId, String text) =>
      _sessions[chatId]?.insert(text) ?? false;

  /// Ends the terminal that belonged to [chatId], if there was one.
  void end(String chatId) {
    final gone = _sessions.remove(chatId);
    if (gone == null) return;
    gone.dispose();
    _publish();
  }

  /// Starts a fresh CLI in a chat whose last one ended, keeping the scrollback.
  ///
  /// Also how a session picks up a connector signed in since it opened: the MCP
  /// config is written when the CLI starts, so a long-running session holds the
  /// tools it was born with.
  void restart(String chatId) =>
      _sessions[chatId]?.restart(onError: _logStartFailure);

  Future<
    ({Map<String, String> environment, String? mcpConfig, List<String> config})
  >
  _setupFor({
    required AgentTool tool,
    required String model,
    required NetworkCredential network,
    required String chatId,
  }) async {
    if (tool == AgentTool.codex) {
      final codex = await codexGridSetup(
        ref,
        network: network,
        model: model,
        conversationId: chatId,
      );
      return (
        environment: codex.environment,
        mcpConfig: null,
        config: codex.config,
      );
    }
    final claude = await claudeGridSetup(
      ref,
      network: network,
      model: model,
      conversationId: chatId,
    );
    return (
      environment: claude.environment,
      mcpConfig: claude.mcpConfig,
      config: const <String>[],
    );
  }

  void _logStartFailure(Object error, StackTrace stack) {
    ref
        .read(appLogProvider)
        .failure(
          'agent',
          'Could not start an agent terminal',
          error: error,
          stackTrace: stack,
        );
  }

  /// Always a fresh state object, even when only a session's own status moved:
  /// the status lives on the session, and a notifier handed back the object it
  /// already holds tells its listeners nothing changed.
  void _publish() => state = _snapshot();

  AgentTerminalsState _snapshot() => AgentTerminalsState(sessions: _sessions);

  void _disposeAll() {
    for (final session in _sessions.values) {
      session.dispose();
    }
    _sessions.clear();
  }
}
