import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/agent_event.dart';
import '../../../infrastructure/cli/agent_resume_point.dart';
import '../../../infrastructure/cli/agent_session_files.dart';
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
import '../../chat/logic/import/claude_session_parser.dart';
import '../../chat/logic/import/codex_session_parser.dart';
import 'adapters/hermes_tool.dart';
import 'agent_catalog.dart';
import 'agent_handover.dart';
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
  /// Two things outlive the launch that started them — [_learnCodexSession] can
  /// be waiting minutes for a rollout, and [_pasteWhenReady] for a prompt — and
  /// a relaunch reuses the **same** `TerminalSession` object, so identity alone
  /// cannot tell either of them that the run they belong to has been replaced.
  /// This can: it is bumped once per launch, and both stop when it moves.
  final Map<String, int> _watch = {};

  /// The first thing a chat has to say, waiting for its CLI to be started with
  /// it — see [prime].
  final Map<String, String> _openingPrompts = {};

  /// Where a Codex session id is read back from. A field so a test can point it
  /// at a temp folder instead of the user's own Codex history.
  final CodexRollouts _rollouts = CodexRollouts();

  /// Where a stored session id is checked against the agent's own disk, for the
  /// same reason and with the same override.
  final AgentSessionFiles _sessionFiles = AgentSessionFiles();

  /// How long a handover waits for the new CLI to open a prompt. Claude Code
  /// and Codex both draw one within a second or two of a warm start; this is
  /// the allowance for a cold one, not the expected wait.
  static const Duration _pasteWindow = Duration(seconds: 30);

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
  ///
  /// [sessions] is every conversation this chat has left behind, not just the
  /// one being picked up: the agent taking over reads its own point, and the
  /// agent being *replaced* is where the handover is read from. Which of them
  /// is which is a fact only this controller has — the view knows the agent the
  /// picker names, not the one still running under it.
  ///
  /// The two are alternatives, never both. An agent that has its own session in
  /// this chat resumes it; only one arriving with nothing is handed the
  /// conversation the agent before it was having.
  Future<void> ensure({
    required String chatId,
    required AgentTool tool,
    required String model,
    required String workdir,
    required AgentApprovalMode approval,
    required NetworkCredential network,
    List<AgentResumePoint> sessions = const [],
    ValueChanged<String>? onSessionId,
  }) async {
    if (!tool.hasInteractiveCli) return;
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
    // Read before [_running] is moved below: this is the agent whose
    // conversation is about to be replaced on screen, and after the switch
    // nothing remembers it was ever here.
    final leaving = live == null ? null : _running[chatId];
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

      // The id the chat remembers is only worth passing while the agent still
      // has the conversation behind it — see [AgentSessionFiles] for how
      // routinely it doesn't, and what `--resume` on a session that is gone
      // costs. A stale one falls through to a new conversation, which is what
      // this chat was going to get anyway.
      final resumeId = await _resumableId(
        tool,
        _pointFor(sessions, tool, workdir)?.sessionId,
      );
      // The chat was closed while its agent's history was being read.
      if (!ref.mounted) return;

      // What the CLI should be holding when it opens. Claude Code is handed an
      // id the app made up; Codex has no way to be told one, so it can only be
      // *resumed* with an id read back off a rollout it wrote (see
      // [_learnCodexSession]).
      final handle = switch ((tool, resumeId)) {
        (_, final id?) => (id: id, resume: true),
        (AgentTool.claude, _) => (id: newAgentSessionId(), resume: false),
        _ => null,
      };
      // Taken here rather than earlier: everything above can still return, and
      // a message consumed by an attempt that never started the CLI would be
      // lost with nothing on screen to say so.
      final command = agentTerminalCommand(
        tool: tool,
        executable: executable,
        model: model,
        workdir: workdir,
        approval: approval,
        mcpConfigPath: setup.mcpConfig,
        config: setup.config,
        session: handle,
        prompt: _openingPrompts.remove(chatId),
      );
      _running[chatId] = tool;
      // Told before the process starts, because the id *is* the flag it starts
      // with: written down now, a chat that is closed mid-answer still knows
      // what to resume.
      if (handle != null && !handle.resume) onSessionId?.call(handle.id);
      // Codex's own id can only be found by watching for the file it writes, so
      // the listing has to be taken before the spawn below.
      final rollouts = tool == AgentTool.codex && resumeId == null
          ? await _rollouts.snapshot()
          : null;
      // Handed back only now: a setup that failed above leaves the CLI that is
      // still running with the tools it had.
      _revokeTools(chatId);
      if (setup.mcpToken case final token?) _mcpTokens[chatId] = token;
      // This launch, so the watchers below stop the moment another replaces it.
      final generation = (_watch[chatId] ?? 0) + 1;
      _watch[chatId] = generation;
      // An agent switched under a chat that already has a terminal takes over
      // that terminal rather than replacing it — see [TerminalSession.relaunch]
      // for the crash that replacing it caused.
      if (_sessions[chatId] case final session?) {
        // What the agent being replaced had worked out — but **only when the
        // agent taking over has nothing of its own here**. Switching back to an
        // agent that already has a conversation in this chat resumes *that*
        // one: it remembers the work first-hand, and pasting the other agent's
        // transcript over the top of its own memory hands it a second, worse
        // account of what it already knows — which is what it did, and what
        // this reads as on screen: a wall of someone else's chat sitting above
        // a prompt that had already picked up where it left off.
        //
        // Read here rather than earlier so the skip also skips the read: a
        // session file runs to megabytes, and parsing one to throw it away is
        // the switch stalling for no reason.
        final handover = resumeId != null
            ? null
            : await _handoverFrom(
                leaving,
                _pointFor(sessions, leaving, workdir),
              );
        if (!ref.mounted) return;
        session.relaunch(
          command: command,
          environment: setup.environment,
          onError: _logStartFailure,
        );
        _learnCodexSession(
          rollouts,
          chatId,
          workdir,
          session,
          onSessionId,
          generation,
        );
        if (handover != null) {
          _pasteWhenReady(chatId, session, handover, generation);
        }
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
      _learnCodexSession(
        rollouts,
        chatId,
        workdir,
        session,
        onSessionId,
        generation,
      );
    } finally {
      _opening.remove(chatId);
    }
  }

  /// The point [tool] left in [workdir], or null when it has none there.
  ///
  /// Both halves of [AgentResumePoint.matches] have to agree, and the folder is
  /// the half that looks optional: an id resumes perfectly well from anywhere,
  /// and the agent would carry on editing the files it remembers rather than
  /// the ones it is now pointed at.
  AgentResumePoint? _pointFor(
    List<AgentResumePoint> sessions,
    AgentTool? tool,
    String workdir,
  ) {
    if (tool == null) return null;
    for (final point in sessions) {
      if (point.matches(thisAgent: tool.id, thisWorkdir: workdir)) return point;
    }
    return null;
  }

  /// The conversation [leaving] was holding, as text for the agent taking over
  /// — or null when there is nothing to hand across.
  ///
  /// **For an agent arriving with nothing, and only then.** A CLI opening on an
  /// empty session has never seen the file the last one was halfway through
  /// changing, and the user's next sentence — usually "keep going" — lands on
  /// nothing. Reading the outgoing agent's own session file is what makes the
  /// difference, and the app already knows how to read both
  /// (`parseClaudeSession`, `parseCodexSession`). An agent that can resume its
  /// own conversation here is never given this: see the caller.
  ///
  /// Every failure here answers null: a session file another tool writes owes
  /// this app no shape, and a handover that could not be built has to cost the
  /// context rather than the switch the user asked for. It is logged, because a
  /// switch that silently lost the history is exactly the thing that would
  /// otherwise be reported as the agent behaving oddly (§6).
  Future<String?> _handoverFrom(
    AgentTool? leaving,
    AgentResumePoint? point,
  ) async {
    if (leaving == null || point == null || leaving == AgentTool.hermes) {
      return null;
    }
    try {
      final file = switch (leaving) {
        AgentTool.claude => await _sessionFiles.claudeSession(point.sessionId),
        AgentTool.codex => await _sessionFiles.codexSession(point.sessionId),
        AgentTool.hermes => null,
      };
      if (file == null) return null;
      final lines = await file.readAsLines();
      final parsed = switch (leaving) {
        AgentTool.claude => parseClaudeSession(
          sessionId: point.sessionId,
          lines: lines,
        ),
        AgentTool.codex => parseCodexSession(
          fallbackSessionId: point.sessionId,
          lines: lines,
        ),
        AgentTool.hermes => null,
      };
      if (parsed == null || parsed.messages.isEmpty) return null;
      return renderAgentHandover(session: parsed, from: leaving);
    } on Object catch (error) {
      ref
          .read(appLogProvider)
          .failure(
            'agent',
            "couldn't read what ${leaving.name} had worked out, so the agent "
                'taking over starts without it',
            error: error,
          );
      return null;
    }
  }

  /// Pastes [text] at the new CLI's prompt as soon as it has one, and leaves it
  /// there **unsent**.
  ///
  /// Unsent because the handover is the user's to send: it is their prompt, it
  /// spends their tokens, and a chat that fires a turn nobody typed the moment
  /// they change a picker is the shape of an app that has been taken over. They
  /// press Enter, or they delete it and start clean.
  ///
  /// The wait is for [TerminalSession.takesPaste] rather than a fixed delay —
  /// an agent CLI prints a banner, an update notice and a tips box before it
  /// draws its composer, and text written into the pty before then is read by
  /// whatever was on screen at the time. It gives up at [_pasteWindow] and says
  /// so: a CLI that never took the keyboard has a bigger problem than a missing
  /// handover, and a paste that lands minutes later would land in the middle of
  /// whatever the user had since typed.
  ///
  /// The opening message of a chat is *not* delivered this way — it is the
  /// CLI's own first argument, which needs no prompt to exist yet and cannot be
  /// eaten by a first-run dialog. See [prime].
  void _pasteWhenReady(
    String chatId,
    TerminalSession session,
    String text,
    int generation,
  ) {
    unawaited(() async {
      final deadline = DateTime.now().add(_pasteWindow);
      while (DateTime.now().isBefore(deadline)) {
        if (!identical(_sessions[chatId], session) ||
            _watch[chatId] != generation) {
          return;
        }
        if (session.paste(text)) return;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      ref
          .read(appLogProvider)
          .info(
            'agent',
            'the agent taking over this chat never opened a prompt, so the '
                'conversation it was handed was not pasted',
          );
    }());
  }

  /// The stored id, if the agent still has the conversation behind it — else
  /// The stored id, if the agent still has the conversation behind it — else
  /// null, and this chat starts a new one.
  ///
  /// The check is the whole fix for a chat that could never be opened twice:
  /// the app writes an id down before the CLI starts, Claude Code only writes
  /// the session on the first turn, so every chat that was looked at and not
  /// typed into came back to `--resume` an id nothing answered to and a CLI
  /// that exited before it drew (see [AgentSessionFiles]). Both the id and the
  /// screen are replaced by the launch that follows, so the chat repairs
  /// itself rather than staying broken for good.
  Future<String?> _resumableId(AgentTool tool, String? sessionId) async {
    if (sessionId == null || sessionId.isEmpty) return null;
    final held = switch (tool) {
      AgentTool.claude => await _sessionFiles.claudeHolds(sessionId),
      AgentTool.codex => await _sessionFiles.codexHolds(sessionId),
      AgentTool.hermes => false,
    };
    if (held) return sessionId;
    ref
        .read(appLogProvider)
        .info(
          'agent',
          '${tool.name} no longer has session $sessionId on this computer; '
              'this chat starts a new conversation',
        );
    return null;
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
    int generation,
  ) {
    if (before == null || onId == null) return;
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

  /// Holds the message a new chat was started with, for the CLI that is about
  /// to open in it.
  ///
  /// **The first message of a terminal chat has no terminal to go to yet.** The
  /// chat is created by pressing Send, and the CLI it belongs to is spawned a
  /// frame later by the view — so the sentence that created the chat would
  /// otherwise be sent down the one-shot lane (`claude -p`) and answered
  /// somewhere the user cannot see, which is exactly what happened: the log
  /// showed the turn running for eleven seconds while the terminal on screen sat
  /// empty.
  ///
  /// Held rather than typed, and handed to the CLI as its own first argument —
  /// see [agentTerminalCommand].
  void prime(String chatId, String message) {
    final text = message.trim();
    if (text.isEmpty) return;
    _openingPrompts[chatId] = text;
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
    _openingPrompts.remove(chatId);
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
