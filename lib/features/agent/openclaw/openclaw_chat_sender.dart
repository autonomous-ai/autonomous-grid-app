import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/command_log.dart';
import '../../../infrastructure/cli/openclaw_infer_service.dart';
import '../../../infrastructure/logging/app_log.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../network/logic/client_app_configurator.dart';
import '../../network/logic/client_app_detector.dart';
import '../../playground/logic/chat_message.dart';
import '../../playground/logic/chat_sender.dart';
import '../../playground/logic/playground_request.dart';
import '../common/agent_prompt.dart';
import '../common/agent_providers.dart';
import '../common/agent_server_error.dart';
import 'openclaw_error.dart';
import 'openclaw_tool.dart';

/// The OpenClaw inference seam, or null when OpenClaw is absent.
final openClawInferServiceProvider = Provider<OpenClawInferService?>((ref) {
  final path = ref.watch(openClawPathProvider);
  return path == null ? null : OpenClawInferServiceImpl(path);
});

/// The `networkId|model` OpenClaw's config was last pointed at, so `openclaw.json`
/// is only rewritten when the grid or model changes.
final openClawConfiguredProvider =
    NotifierProvider<OpenClawConfigured, String?>(OpenClawConfigured.new);

class OpenClawConfigured extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? key) => state = key;
}

/// A [ChatSender] backed by OpenClaw over `openclaw infer model run --json`.
///
/// One-shot per turn, like Codex — but the CLI exposes no thread/resume here, so
/// there's no continuity to hold: every turn replays the whole history in the
/// prompt. It points `openclaw.json` at the grid first (reusing the same
/// [ClientAppConfigurator] the connect-your-apps guide uses), then runs one
/// inference and streams the finished answer into the bubble.
///
/// Developer-only for now (see `OpenClawAgent.devOnly`): the transport is wired
/// to the documented CLI but hasn't been verified against a live OpenClaw, so it
/// is kept out of shipped releases until it has.
final openClawChatSenderProvider = Provider<ChatSender>(
  (ref) => OpenClawChatSender(ref),
);

class OpenClawChatSender implements ChatSender {
  OpenClawChatSender(this._ref);

  final Ref _ref;

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
  }) async* {
    if (modality != PlaygroundModality.text) {
      yield const ChatSendFailure('The agent can only answer in text.');
      return;
    }
    if (_ref.read(openClawInferServiceProvider) == null) {
      yield const ChatSendFailure(
        "This computer isn't set up to answer chats yet. Open the account menu "
        '▸ This computer to finish setting it up.',
      );
      return;
    }
    if (history.isEmpty || history.last.text.trim().isEmpty) {
      yield const ChatSendFailure('Nothing to send.');
      return;
    }

    final pointed = await _pointAtGrid(network, model);
    if (pointed != null) {
      yield ChatSendFailure(pointed);
      return;
    }

    final root = workdir ?? _ref.read(agentWorkspaceDirProvider).path;
    final prompt = planFirst
        ? withPlanPreamble(buildAgentPrompt(history))
        : buildAgentPrompt(history);

    yield* _runTurn(
      workdir: root,
      prompt: withProjectInstructions(prompt, instructions),
      // Grid is written into `openclaw.json` as the `grid` provider (see
      // `_applyOpenClaw`), so the CLI selects it as `grid/<model>`.
      model: 'grid/$model',
      logModel: model,
    );
  }

  /// Run one turn: one inference, then the finished reply. Driven by an explicit
  /// [StreamController] (not `await for`) so Stop tears the process down there
  /// and then — cancelling the stream kills the `openclaw` process.
  Stream<ChatSendUpdate> _runTurn({
    required String workdir,
    required String prompt,
    required String model,
    required String logModel,
  }) {
    // OpenClaw streams no tool steps, but a prior agent's feed would otherwise
    // linger under its answer — start the turn with none.
    _ref.read(agentActivityProvider.notifier).clear();
    _ref.read(agentPlanProvider.notifier).clear();
    _ref.read(agentSourcesProvider.notifier).clear();
    final log = _ref.read(commandLogProvider.notifier);
    final logId = log.begin(
      CliCallKind.start,
      'openclaw infer -m $logModel (agent)',
    );

    final run = _ref
        .read(openClawInferServiceProvider)!
        .run(prompt: prompt, model: model, workdir: workdir);

    final updates = StreamController<ChatSendUpdate>();
    var settled = false;

    run.reply
        .then((text) {
          settled = true;
          final reply = text.trim();
          final error = reply.isEmpty ? kAgentNoAnswer : null;
          log.finish(logId, error: error);
          updates.add(
            error != null
                ? ChatSendFailure(error)
                : ChatSendSuccess(
                    ChatMessage(role: ChatRole.assistant, text: reply),
                  ),
          );
          updates.close();
        })
        .catchError((Object error) {
          settled = true;
          final message = error is OpenClawInferException
              ? (error.retryable
                    ? "Couldn't start OpenClaw on this computer. Try sending "
                          'again.'
                    : friendlyOpenClawError(error.message))
              : "OpenClaw couldn't finish: $error";
          log.finish(logId, error: message);
          _ref.read(appLogProvider).failure('agent', 'openclaw turn: $error');
          updates.add(ChatSendFailure(message));
          updates.close();
        });

    // The user hit Stop (or left the chat). A clean finish lands here too, with
    // [settled] set, and must not re-kill anything.
    updates.onCancel = () {
      if (settled) return;
      run.kill();
      log.finish(logId, error: 'stopped');
    };
    return updates.stream;
  }

  /// Ensure `openclaw.json` points at [network] with [model] (idempotent, only
  /// rewritten when the grid or model changed). Returns null on success, else a
  /// user-facing error line.
  Future<String?> _pointAtGrid(NetworkCredential network, String model) async {
    final key = '${network.networkId}|$model';
    if (_ref.read(openClawConfiguredProvider) == key) return null;
    final result = await _ref.read(clientAppConfiguratorProvider).apply(
      ClientApp.openClaw,
      network.relayBaseUrl,
      network.relayApiKey,
      [model],
    );
    if (result is ApplyError) {
      return "Couldn't point OpenClaw at this grid: ${result.message}";
    }
    _ref.read(openClawConfiguredProvider.notifier).set(key);
    return null;
  }
}
