import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/cli/agent_session_id.dart';
import '../../../infrastructure/cli/codex_rollouts.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../../infrastructure/mcp/grid_mcp_provider.dart';
import '../../../infrastructure/mcp/grid_mcp_server.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/terminal/terminal_session.dart';
import 'adapters/agent_grid_setup.dart';
import 'adapters/agent_terminal_command.dart';
import 'adapters/claude_tool.dart';
import 'adapters/codex_tool.dart';
import 'adapters/hermes_tool.dart';
import 'agent_catalog.dart';
import 'agent_model_support.dart';

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

  /// The Grid-tools grant each session is holding, so ending one takes its
  /// access with it. A session's grant has no expiry of its own — that is the
  /// point of it (see [GridMcpServer.mintSessionToken]) — so this is the only
  /// thing that ever gives it back.
  final Map<String, String> _mcpTokens = {};

  /// Which agent each live session is actually running, so [ensure] can tell a
  /// chat that has merely rebuilt from one whose agent has been switched under
  /// it. The session itself can't answer that — it holds an argv, and
  /// `TerminalSession` is the Terminal tab's too.
  final Map<String, AgentTool> _running = {};

  /// Which run of a chat's terminal is the current one.
  ///
  /// [_learnCodexSession] can be waiting for minutes, and a relaunch reuses the
  /// **same** `TerminalSession` object — so identity alone cannot tell the
  /// watcher for the run that has been replaced to stop. This can.
  final Map<String, int> _watch = {};

  /// Where a Codex session id is read back from. A field so a test can point it
  /// at a temp folder instead of the user's own Codex history.
  final CodexRollouts _rollouts = CodexRollouts();

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
    String? resumeSessionId,
    ValueChanged<String>? onSessionId,
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
    final live = _sessions[chatId];
    // Already this agent — a rebuild, not a switch.
    if (live != null && _running[chatId] == tool) return;
    // The agent has been switched, but the model has not caught up yet:
    // switching moves it (`_retargetModel`) a frame later, and starting Codex
    // on `claude:opus` spends a session on a refusal the grid is right to make.
    // The next build arrives with the pair settled and starts it then.
    //
    // TODO(BE): when the pair can *never* settle, this waits for ever and the
    // picker lies. The agent menu lets a user pick an agent it has already
    // labelled "No model on this grid it can answer with"
    // (`agentHasModelHereProvider`); `_retargetModel` then finds nothing to
    // move to, so the chat goes on showing — and typing into — the agent that
    // was running before, under a picker naming the new one. It is not a
    // regression (a switch never reached a running terminal at all before
    // this), but it wants the view to say "Codex can't answer on this grid"
    // where it currently shows the wrong CLI.
    if (live != null && !agentSupportsModel(tool, model)) return;
    if (!_opening.add(chatId)) return;
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

      // What the CLI should be holding when it opens. Claude Code is handed an
      // id the app made up; Codex has no way to be told one, so it can only be
      // *resumed* with an id read back off a rollout it wrote (see
      // [_learnCodexSession]).
      final handle = switch ((tool, resumeSessionId)) {
        (_, final id?) => (id: id, resume: true),
        (AgentTool.claude, _) => (id: newAgentSessionId(), resume: false),
        _ => null,
      };
      final command = agentTerminalCommand(
        tool: tool,
        executable: executable,
        model: model,
        workdir: workdir,
        approval: approval,
        mcpConfigPath: setup.mcpConfig,
        config: setup.config,
        session: handle,
      );
      _running[chatId] = tool;
      // Told before the process starts, because the id *is* the flag it starts
      // with: written down now, a chat that is closed mid-answer still knows
      // what to resume.
      if (handle != null && !handle.resume) onSessionId?.call(handle.id);
      // Codex's own id can only be found by watching for the file it writes, so
      // the listing has to be taken before the spawn below.
      final rollouts = tool == AgentTool.codex && resumeSessionId == null
          ? await _rollouts.snapshot()
          : null;
      // Handed back only now: a setup that failed above leaves the CLI that is
      // still running with the tools it had.
      _revokeTools(chatId);
      if (setup.mcpToken case final token?) _mcpTokens[chatId] = token;
      // An agent switched under a chat that already has a terminal takes over
      // that terminal rather than replacing it — see [TerminalSession.relaunch]
      // for the crash that replacing it caused.
      if (_sessions[chatId] case final session?) {
        session.relaunch(
          command: command,
          environment: setup.environment,
          onError: _logStartFailure,
        );
        _learnCodexSession(rollouts, chatId, workdir, session, onSessionId);
        return;
      }
      final session = TerminalSession(
        id: chatId,
        workdir: workdir,
        command: command,
        environment: setup.environment,
        onChanged: _publish,
      );
      _sessions[chatId] = session;
      session.start(onError: _logStartFailure);
      _publish();
      _learnCodexSession(rollouts, chatId, workdir, session, onSessionId);
    } finally {
      _opening.remove(chatId);
    }
  }

  /// Reads back the id Codex gave this chat's session, and hands it to
  /// [onSessionId].
  ///
  /// Not awaited by [ensure], and it cannot be: Codex writes its rollout on the
  /// **first turn**, not at start-up (see [CodexRollouts.discover]), so this may
  /// be waiting for as long as it takes the user to type. The chat is usable
  /// throughout — all this decides is whether *tomorrow's* launch continues the
  /// conversation or starts another.
  ///
  /// It stops when the terminal it is watching stops being this chat's: closed,
  /// restarted, or handed to another agent. Otherwise a chat opened and left
  /// alone would keep a directory listing going for the life of the app, and a
  /// restarted one would have two watchers racing to name it.
  void _learnCodexSession(
    Set<String>? before,
    String chatId,
    String workdir,
    TerminalSession session,
    ValueChanged<String>? onId,
  ) {
    if (before == null || onId == null) return;
    final generation = (_watch[chatId] ?? 0) + 1;
    _watch[chatId] = generation;
    unawaited(
      _rollouts
          .discover(
            before: before,
            workdir: workdir,
            keepWaiting: () =>
                identical(_sessions[chatId], session) &&
                _watch[chatId] == generation,
          )
          .then((id) {
            if (id == null) {
              return ref
                  .read(appLogProvider)
                  .info(
                    'agent',
                    'the Codex terminal closed before it started a session; '
                        'this chat will begin a new one next time',
                  );
            }
            onId(id);
          }),
    );
  }

  /// Puts [text] at the CLI's prompt without submitting it — a dropped file's
  /// path, landing where the user is still writing the rest of the line.
  ///
  /// False when this chat has no terminal running, so a caller can fall back to
  /// what it would have done otherwise.
  bool insert(String chatId, String text) =>
      _sessions[chatId]?.insert(text) ?? false;

  /// Ends the terminal that belonged to [chatId], if there was one.
  void end(String chatId) {
    _running.remove(chatId);
    _watch.remove(chatId);
    final gone = _sessions.remove(chatId);
    if (gone == null) return;
    _revokeTools(chatId);
    gone.dispose();
    _publish();
  }

  /// Hands back the session's Grid-tools grant. Nothing else expires it, so a
  /// session ended without this leaves a live key to the user's chat behind.
  void _revokeTools(String chatId) {
    final token = _mcpTokens.remove(chatId);
    if (token == null) return;
    ref.read(gridMcpServerProvider).revoke(token);
  }

  /// Starts the chat's agent again from scratch, on the settings it has now.
  ///
  /// The escape hatch for a CLI that has wedged, and the one way to pick up
  /// something a running session was born with and cannot be told about — a
  /// connector signed in since it opened, an access mode changed since. It
  /// forgets which agent is running so [ensure] takes its relaunch path even
  /// though nothing about the request has changed.
  ///
  /// **It begins a new conversation**, because the CLI is a new process and the
  /// screen above belonged to the one it replaces. That is why this is a button
  /// the user presses rather than something a rebuild does by itself.
  Future<void> reopen({
    required String chatId,
    required AgentTool tool,
    required String model,
    required String workdir,
    required AgentApprovalMode approval,
    required NetworkCredential network,
    ValueChanged<String>? onSessionId,
  }) async {
    _running.remove(chatId);
    await ensure(
      chatId: chatId,
      tool: tool,
      model: model,
      workdir: workdir,
      approval: approval,
      network: network,
      // No `resumeSessionId`, and that is the point of the button: Restart is
      // what a user reaches for to be rid of the conversation on screen, so it
      // starts a new one and [onSessionId] replaces the id the chat had stored.
      onSessionId: onSessionId,
    );
  }

  /// Starts a fresh CLI in a chat whose last one ended, keeping the scrollback.
  ///
  /// Also how a session picks up a connector signed in since it opened: the MCP
  /// config is written when the CLI starts, so a long-running session holds the
  /// tools it was born with.
  void restart(String chatId) =>
      _sessions[chatId]?.restart(onError: _logStartFailure);

  /// The grid setup for one session, asked for as a **session** rather than as a
  /// turn: the CLI opens its MCP connection once and holds it, so its grant has
  /// to outlive every turn the app sends into the same chat beside it. See
  /// [GridMcpServer.mintSessionToken].
  Future<
    ({
      Map<String, String> environment,
      String? mcpConfig,
      List<String> config,
      String? mcpToken,
    })
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
        session: true,
      );
      return (
        environment: codex.environment,
        mcpConfig: null,
        config: codex.config,
        mcpToken: codex.mcpToken,
      );
    }
    final claude = await claudeGridSetup(
      ref,
      network: network,
      model: model,
      conversationId: chatId,
      session: true,
    );
    return (
      environment: claude.environment,
      mcpConfig: claude.mcpConfig,
      config: const <String>[],
      mcpToken: claude.mcpToken,
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
    // The server is stopped with the app and clears its own grants, so this is
    // belt and braces — but the map outlives a *hot restart*, which the server
    // does not, and a token left here would name a grant nobody holds.
    _mcpTokens.clear();
    for (final session in _sessions.values) {
      session.dispose();
    }
    _sessions.clear();
  }
}
