import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/command_log.dart';
import '../../../infrastructure/cli/hermes_acp_service.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../network/logic/client_app_configurator.dart';
import '../../network/logic/client_app_detector.dart';
import '../../playground/logic/chat_message.dart';
import '../../playground/logic/chat_sender.dart';
import '../../playground/logic/playground_request.dart';
import 'agent_prompt.dart';
import 'agent_tool.dart';
import 'codex_providers.dart';

/// The hermes ACP seam, or null when hermes is absent.
final hermesAcpServiceProvider = Provider<HermesAcpService?>((ref) {
  final path = ref.watch(agentToolPathProvider(AgentTool.hermes));
  return path == null ? null : HermesAcpServiceImpl(path);
});

/// The `networkId|model` Hermes's config was last pointed at, so we only rewrite
/// `~/.hermes` when the target grid or model changes. ACP reads the model from
/// config (no inline endpoint/model flag), so the config must carry the current
/// selection.
final hermesConfiguredProvider = NotifierProvider<HermesConfigured, String?>(
  HermesConfigured.new,
);

class HermesConfigured extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? key) => state = key;
}

/// The Agent-mode [ChatSender] backed by Hermes via ACP (Agent Client Protocol).
///
/// Unlike codex, Hermes talks OpenAI chat/completions, so it works with the grid
/// today. ACP streams `tool_call` / `agent_message_chunk` updates, so this feeds
/// the same live activity feed ([codexActivityProvider]) codex uses — the user
/// sees each shell command and file read as it happens.
final hermesChatSenderProvider = Provider<ChatSender>(
  (ref) => HermesChatSender(ref),
);

class HermesChatSender implements ChatSender {
  HermesChatSender(this._ref);

  final Ref _ref;

  @override
  Stream<ChatSendUpdate> send({
    required NetworkCredential network,
    required String model,
    required List<ChatMessage> history,
    PlaygroundModality modality = PlaygroundModality.text,
    List<MediaAttachment> attachments = const [],
    String? localBaseUrl,
  }) async* {
    if (modality != PlaygroundModality.text) {
      yield const ChatSendFailure('Agent mode only supports text chat.');
      return;
    }
    final service = _ref.read(hermesAcpServiceProvider);
    if (service == null) {
      yield const ChatSendFailure(
        "Hermes isn't installed for Agent mode. Pick Hermes again to install "
        'it.',
      );
      return;
    }
    final prompt = buildAgentPrompt(history);
    if (prompt.isEmpty) {
      yield const ChatSendFailure('Nothing to send.');
      return;
    }

    final pointed = await _pointAtGrid(network, model);
    if (pointed != null) {
      yield ChatSendFailure(pointed);
      return;
    }

    final workdir = _ref.read(agentWorkspaceDirProvider).path;
    final activityLog = _ref.read(codexActivityProvider.notifier)..clear();
    final log = _ref.read(commandLogProvider.notifier);
    final logId = log.begin(CliCallKind.start, 'hermes acp -m $model (agent)');

    final run = service.prompt(text: prompt, workdir: workdir);
    final answer = StringBuffer();
    var settled = false;
    try {
      await for (final event in run.events) {
        switch (event) {
          case HermesAcpActivity(:final activity):
            activityLog.upsert(activity);
          case HermesAcpMessage(:final text):
            answer.write(text);
        }
      }
      settled = true;
    } finally {
      if (!settled) run.kill();
    }
    await run.done;

    final text = answer.toString().trim();
    log.finish(logId, error: text.isEmpty ? 'no output' : null);

    if (text.isNotEmpty) {
      yield ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: text));
      return;
    }
    yield const ChatSendFailure("The agent didn't return an answer.");
  }

  /// Ensures `~/.hermes` points at [network] with [model] (idempotent, only
  /// rewritten when the grid or model changed). Returns null on success, else a
  /// user-facing error line.
  Future<String?> _pointAtGrid(NetworkCredential network, String model) async {
    final key = '${network.networkId}|$model';
    if (_ref.read(hermesConfiguredProvider) == key) return null;
    final result = await _ref.read(clientAppConfiguratorProvider).apply(
      ClientApp.hermes,
      network.relayBaseUrl,
      network.relayApiKey,
      [model],
    );
    if (result is ApplyError) {
      return "Couldn't point Hermes at this grid: ${result.message}";
    }
    _ref.read(hermesConfiguredProvider.notifier).set(key);
    return null;
  }
}
