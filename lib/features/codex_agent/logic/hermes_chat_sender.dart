import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/command_log.dart';
import '../../../infrastructure/cli/hermes_agent_service.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../network/logic/client_app_configurator.dart';
import '../../network/logic/client_app_detector.dart';
import '../../playground/logic/chat_message.dart';
import '../../playground/logic/chat_sender.dart';
import '../../playground/logic/playground_request.dart';
import 'agent_prompt.dart';
import 'agent_tool.dart';
import 'codex_providers.dart';

/// The hermes seam, or null when hermes is absent.
final hermesAgentServiceProvider = Provider<HermesAgentService?>((ref) {
  final path = ref.watch(agentToolPathProvider(AgentTool.hermes));
  return path == null ? null : HermesAgentServiceImpl(path);
});

/// The grid id Hermes's config was last pointed at, so we only rewrite
/// `~/.hermes` when the target grid actually changes (Hermes has no inline
/// base-url/key flag — the endpoint must live in its config).
final hermesConfiguredGridProvider =
    NotifierProvider<HermesConfiguredGrid, String?>(HermesConfiguredGrid.new);

class HermesConfiguredGrid extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? networkId) => state = networkId;
}

/// The Agent-mode [ChatSender] backed by Hermes: routes a Chat-tab turn through
/// `hermes -z` (one-shot, read-only), driven by the selected grid model.
///
/// Unlike codex, Hermes talks OpenAI chat/completions, so it works with the grid
/// today. It has no inline endpoint flag, so we point `~/.hermes` at the grid via
/// the shared [ClientAppConfigurator] — but only when the target grid changes,
/// to avoid rewriting the user's config on every message.
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
    final service = _ref.read(hermesAgentServiceProvider);
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
    final log = _ref.read(commandLogProvider.notifier);
    final logId = log.begin(CliCallKind.start, 'hermes -z -m $model (agent)');

    final run = service.run(
      args: ['-z', prompt, '-m', model, '--safe-mode'],
      environment: const {},
      workdir: workdir,
    );

    final answer = StringBuffer();
    var settled = false;
    try {
      await for (final line in run.lines) {
        if (answer.isNotEmpty) answer.write('\n');
        answer.write(line);
      }
      settled = true;
    } finally {
      if (!settled) run.kill();
    }

    final exit = await run.exitCode;
    final text = answer.toString().trim();
    log.finish(logId, exitCode: exit, error: text.isEmpty ? 'no output' : null);

    if (text.isNotEmpty) {
      yield ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: text));
      return;
    }
    yield ChatSendFailure(_humanize(exit));
  }

  /// Ensures `~/.hermes` points at [network] (idempotent, only rewritten when the
  /// grid changed). Returns null on success, else a user-facing error line.
  Future<String?> _pointAtGrid(NetworkCredential network, String model) async {
    if (_ref.read(hermesConfiguredGridProvider) == network.networkId) {
      return null;
    }
    final result = await _ref.read(clientAppConfiguratorProvider).apply(
      ClientApp.hermes,
      network.relayBaseUrl,
      network.relayApiKey,
      [model],
    );
    if (result is ApplyError) {
      return "Couldn't point Hermes at this grid: ${result.message}";
    }
    _ref.read(hermesConfiguredGridProvider.notifier).set(network.networkId);
    return null;
  }

  static String _humanize(int exit) =>
      "The agent didn't respond (exit code $exit).";
}
