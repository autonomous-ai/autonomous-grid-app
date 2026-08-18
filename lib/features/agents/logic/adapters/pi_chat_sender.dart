import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/grid_paths.dart';
import '../../../../infrastructure/cli/agent_event.dart';
import '../../../../infrastructure/cli/agent_resume_point.dart';
import '../../../../infrastructure/cli/command_log.dart';
import '../../../../infrastructure/cli/pi_exec_service.dart';
import '../../../../infrastructure/logging/app_log.dart';
import '../../../../infrastructure/state/models/network_credential.dart';
import '../../../../shared/copy/setup_hints.dart';
import '../../../playground/logic/chat_message.dart';
import '../../../playground/logic/chat_sender.dart';
import '../../../playground/logic/playground_request.dart';
import '../agent_changes.dart';
import '../agent_prompt.dart';
import '../agent_server_error.dart';
import '../agent_session_slots.dart';
import '../agent_turn_log.dart';
import '../agent_providers.dart';
import 'pi_grid_config.dart';
import 'pi_tool.dart';

/// The Pi exec seam, or null when Pi is absent.
final piExecServiceProvider = Provider<PiExecService?>((ref) {
  final path = ref.watch(piPathProvider);
  return path == null ? null : PiExecServiceImpl(path);
});

/// Where Pi's conversations are kept (`~/.grid/app/pi/sessions`).
///
/// Outside the per-run config dir on purpose: that one is a temp folder thrown
/// away at the end of every turn, and a session filed in it would take the
/// conversation with it — `--session <id>` would then find nothing to resume.
final piSessionDirProvider = Provider<Directory>(
  (ref) => Directory('${GridPaths.home.path}/app/pi/sessions'),
);

/// A [ChatSender] backed by Pi over `pi --mode json`.
///
/// Pi runs one turn per process and exits, so — like Codex, unlike Hermes's
/// persistent ACP session — continuity comes from **resuming the session**: the
/// first turn replays the history and learns Pi's session id, and each later
/// turn sends only the new message with `pi --session <id>`. Switching
/// conversation, grid or model starts a fresh session.
///
/// The grid it answers with is handed over **per run** in an app-owned Pi config
/// dir (`PI_CODING_AGENT_DIR`) — a fresh `models.json` naming the grid provider,
/// the key in the child's environment ([piGridEnvironment]) — so nothing of the
/// user's `~/.pi` is written or repointed. A `settings.json` there passes the
/// user's own `~/.pi/agent/skills` through, so an app turn still loads the skills
/// the Skills screen manages.
///
/// It runs with `--no-approve` ([kPiNoApproveFlag]), so the folder the chat
/// opens in never gets to hand Pi its own extensions or settings. Pi still
/// changes files and runs commands on this computer and has no channel to ask
/// first, so nothing here prompts the user. TODO(BE): Pi is now the **only**
/// chat agent with that gap — Hermes, Claude Code and Codex all ask — so the
/// approval picker means nothing on a Pi chat while appearing to.
final piChatSenderProvider = Provider<ChatSender>((ref) {
  return PiChatSender(ref);
});

class PiChatSender implements ChatSender {
  PiChatSender(this._ref);

  final Ref _ref;

  final _slots = AgentSessionSlots();

  @override
  Stream<ChatSendUpdate> send({
    required NetworkCredential network,
    required String model,
    required List<ChatMessage> history,
    PlaygroundModality modality = PlaygroundModality.text,
    List<MediaAttachment> attachments = const [],
    String? localBaseUrl,
    String? workdir,
    String? conversationId,
    String? instructions,
    bool planFirst = false,
    // Pi has no permission channel at all — it never stops to ask, so there is
    // nothing here to hold it to.
    AgentApprovalMode? approval,
    // Pi resumes by `--session <id>`, but the app has never written one of its
    // ids down and nothing imports Pi sessions — so there is never a point to
    // adopt here. Accepted to satisfy the interface, deliberately unused.
    AgentResumePoint? resume,
  }) async* {
    if (modality != PlaygroundModality.text) {
      yield const ChatSendFailure('The agent can only answer in text.');
      return;
    }
    if (_ref.read(piExecServiceProvider) == null) {
      yield ChatSendFailure(notSetUpToMessage('answer chats'));
      return;
    }
    if (history.isEmpty || history.last.text.trim().isEmpty) {
      yield const ChatSendFailure('Nothing to send.');
      return;
    }

    // Everything this turn publishes is filed under its conversation, so two
    // chats answering at once never show each other's work. See [AgentRuns.reset].
    final chat = conversationId ?? '';
    _ref.read(agentRunsProvider.notifier).reset(chat);

    final root = workdir ?? _ref.read(agentWorkspaceDirProvider).path;
    final turn = _slots.planTurn(
      key: '${network.networkId}|$model|$conversationId|$root',
      conversationId: conversationId,
      history: history,
    );
    final prompt = planFirst ? withPlanPreamble(turn.text) : turn.text;

    // The run's own Pi config dir — fresh per turn, cleaned up when it ends, so
    // two concurrent turns never race on one `models.json`.
    final configDir = await Directory.systemTemp.createTemp('grid-pi-cfg-');
    await File(
      '${configDir.path}/models.json',
    ).writeAsString(piModelsJson(base: network.relayBaseUrl, model: model));
    await File('${configDir.path}/settings.json').writeAsString(
      piSettingsJson(userSkillsDir: '${GridPaths.userHome}/.pi/agent/skills'),
    );
    final sessionDir = _ref.read(piSessionDirProvider);
    await sessionDir.create(recursive: true);

    yield* _runTurn(
      workdir: root,
      prompt: withProjectInstructions(
        prompt,
        turn.freshStart ? instructions : null,
      ),
      resumeSessionId: turn.resumeSessionId,
      model: model,
      environment: piGridEnvironment(
        configDir: configDir.path,
        sessionDir: sessionDir.path,
        apiKey: network.relayApiKey,
      ),
      configDir: configDir,
      slot: turn.slot,
      chat: chat,
    );
  }

  /// Run one turn: stream the answer into the bubble as it arrives, mirror tool
  /// steps into the activity feed, and end with the finished reply.
  ///
  /// Driven by an explicit subscription (not `await for`) so Stop tears the turn
  /// down there and then — cancelling the stream kills the `pi` process.
  Stream<ChatSendUpdate> _runTurn({
    required String workdir,
    required String prompt,
    required String? resumeSessionId,
    required String model,
    required Map<String, String> environment,
    required Directory configDir,
    required AgentSessionSlot slot,
    required String chat,
  }) {
    final runs = _ref.read(agentRunsProvider.notifier);
    final log = _ref.read(commandLogProvider.notifier);
    final logId = log.begin(
      CliCallKind.start,
      'pi --mode json -m $model (agent)',
      detail: agentTurnDetail(
        args: [
          'pi',
          ...piExecArgs(model: model, resumeSessionId: resumeSessionId),
        ],
        workdir: workdir,
        environment: environment,
        prompt: prompt,
      ),
    );

    final service = _ref.read(piExecServiceProvider)!;
    final run = service.run(
      workdir: workdir,
      prompt: prompt,
      model: model,
      environment: environment,
      resumeSessionId: resumeSessionId,
    );

    final answer = StringBuffer();
    final updates = StreamController<ChatSendUpdate>();
    String? failure;
    var settled = false;
    var lostSession = false;

    final events = run.events.listen(
      (event) {
        switch (event) {
          case PiSessionStarted(:final sessionId):
            slot.sessionId = sessionId;
          case PiActivityEvent(:final activity):
            // With what has been said so far, so the step lands *after* that
            // passage in the turn's timeline rather than under the whole answer.
            runs.upsertStep(chat, activity, answer: answer.toString());
          case PiFileChangeEvent(:final paths, :final step):
            // The write's own row rides on this event — nothing else reports it
            // finished (see [PiFileChangeEvent.step]).
            if (step != null) {
              runs.upsertStep(chat, step, answer: answer.toString());
            }
            _recordAddedFiles(chat, paths);
          case PiMessageEvent(:final text):
            answer
              ..clear()
              ..write(text);
            updates.add(ChatSendStreaming(text));
          case PiTurnFailed(:final message):
            lostSession = piLostSession(message);
            failure = friendlyPiError(message);
            _logRaw(message);
          // The exchange settled with no error: what streamed above is all of
          // it, and the reply goes out from [onDone] below.
          case PiTurnCompleted():
        }
      },
      onError: (Object error) {
        failure = error is PiExecException
            ? (error.retryable
                  ? "Couldn't start Pi on this computer. Try sending again."
                  : "Couldn't start Pi on this computer. ${error.message}")
            : friendlyPiError('$error');
        _logRaw('$error');
      },
      onDone: () async {
        await run.done;
        settled = true;
        final reply = answer.toString().trim();
        final error = failure ?? (reply.isEmpty ? kAgentNoAnswer : null);
        log.finish(logId, error: error);
        if (error == null) {
          // Pi's own session already holds the answer it just wrote, so count
          // it as seen — the next turn won't quote it back as "context you
          // missed". Only on success: a failed turn appends nothing.
          slot.seen++;
        } else if (lostSession) {
          // The conversation Pi was resuming is gone from its session folder,
          // so this slot can only fail the same way again. Drop it: the next
          // send starts a session and replays the chat into it.
          _slots.forget(chat);
        }
        updates.add(
          error != null
              ? ChatSendFailure(error)
              : ChatSendSuccess(
                  ChatMessage(role: ChatRole.assistant, text: reply),
                ),
        );
        await updates.close();
        await _cleanup(configDir);
      },
    );

    updates.onCancel = () async {
      await events.cancel();
      if (settled) return;
      run.kill();
      log.finish(logId, error: 'stopped');
      await _cleanup(configDir);
    };
    return updates.stream;
  }

  /// Drop the run's throwaway config dir. Best effort — a dir already gone (the
  /// done and cancel paths can both fire) is not an error.
  Future<void> _cleanup(Directory configDir) async {
    try {
      if (await configDir.exists()) await configDir.delete(recursive: true);
    } on Object {
      // A temp dir the OS will reap anyway is not worth failing a turn over.
    }
  }

  /// Record every file Pi freshly wrote so the chat can offer to open it — the
  /// point of a "make me a page or a game" turn (see `AgentChangesBar`).
  void _recordAddedFiles(String chat, List<String> paths) {
    final changesLog = _ref.read(agentChangesProvider.notifier);
    for (final path in paths) {
      unawaited(_recordAddedFile(chat, path, changesLog));
    }
  }

  /// Read the just-written file so its "before → after" diff shows the whole new
  /// file, and record it with a null [AgentChange.before] so undo deletes it.
  Future<void> _recordAddedFile(
    String chat,
    String path,
    AgentChangesController changesLog,
  ) async {
    String after;
    try {
      after = await File(path).readAsString();
    } on Object {
      after = '';
    }
    changesLog.record(chatId: chat, path: path, before: null, after: after);
  }

  /// Keep Pi's own words for the log while the chat shows the friendly line.
  void _logRaw(String raw) =>
      _ref.read(appLogProvider).failure('agent', 'pi turn failed: $raw');
}

/// Whether [raw] is Pi refusing to resume a conversation it can't find — it
/// exits with `No session found matching '<id>'` and says nothing else.
bool piLostSession(String raw) => raw.contains('No session found');

/// Humanize Pi's failure so the chat shows a next step, not a stack trace.
///
/// Pi answers the grid over OpenAI chat-completions, so the failures a user hits
/// are the shared relay ones — an empty/again body, or an `HTTP <status>`
/// envelope — routed through the same helpers every agent uses. Anything else
/// keeps Pi's own last line, which at least says what it was doing.
String friendlyPiError(String raw) {
  // A session id no longer on disk is not the user's problem to read: the chat
  // has already been forgotten on this side, so the fix is one more send.
  if (piLostSession(raw)) {
    return 'Pi lost track of this conversation. Send your message again to '
        'start it over.';
  }
  final empty = friendlyAgentEmptyResponse(raw);
  if (empty != null) return empty;
  final server = friendlyAgentServerError(raw);
  if (server != null) return server;

  final detail = raw
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .lastOrNull;
  if (detail == null || detail.isEmpty) {
    return "Pi couldn't finish. Check your connection and try again.";
  }
  return "Pi couldn't finish: $detail";
}
