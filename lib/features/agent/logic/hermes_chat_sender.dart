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
import 'hermes_tool.dart';
import 'agent_providers.dart';
import 'hermes_skill_installer.dart';

/// The hermes ACP seam, or null when hermes is absent.
final hermesAcpServiceProvider = Provider<HermesAcpService?>((ref) {
  final path = ref.watch(hermesPathProvider);
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

/// The chat's default [ChatSender], backed by Hermes over ACP (Agent Client
/// Protocol).
///
/// It keeps **one live `hermes acp` session per conversation**. The process is
/// spawned once, the handshake runs once, and each turn sends only the new
/// message — Hermes holds the conversation context itself. Switching
/// conversation, grid or model starts a fresh session. The old sender re-spawned
/// the process and resent the entire history every turn, which got slower and
/// more token-hungry the longer a chat ran.
///
/// ACP streams `tool_call` / `agent_message_chunk` updates, so this feeds the
/// live activity feed ([agentActivityProvider]) and streams the answer into the
/// bubble as it's generated.
final hermesChatSenderProvider = Provider<ChatSender>((ref) {
  final sender = HermesChatSender(ref);
  ref.onDispose(sender.dispose);
  return sender;
});

/// A live Hermes session and what it has already seen, so the sender can decide
/// between continuing it (send only the new turn) and restarting it.
class _LiveSession {
  _LiveSession({required this.session, required this.key, required this.seen});

  final HermesAcpSession session;

  /// `networkId|model|conversationId` — a change in any of these means a new
  /// session (a different grid, model, or conversation).
  final String key;

  /// The history length at the last prompt. A longer history next time is a
  /// continuation of the same chat; anything else restarts.
  int seen;
}

class HermesChatSender implements ChatSender {
  HermesChatSender(this._ref);

  final Ref _ref;
  _LiveSession? _live;

  /// Kill any live session — wired to the provider's dispose.
  Future<void> dispose() async {
    await _live?.session.close();
    _live = null;
  }

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
  }) async* {
    if (modality != PlaygroundModality.text) {
      yield const ChatSendFailure('The agent can only answer in text.');
      return;
    }
    if (_ref.read(hermesAcpServiceProvider) == null) {
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

    final HermesAcpSession session;
    final String text;
    try {
      final resolved = await _sessionFor(
        network,
        model,
        conversationId,
        history,
        workdir,
      );
      session = resolved.session;
      text = resolved.text;
    } on HermesAcpException {
      yield const ChatSendFailure(
        "Couldn't start the agent on this computer. Try sending again.",
      );
      return;
    }

    // Hand the session's id to the caller: Hermes names its own sessions, and
    // the Chat tab uses that name for the conversation once it lands.
    if (session.sessionId case final id?) yield ChatSendAgentSession(id);

    yield* _runTurn(session, text, model);
  }

  /// Reuse the live session when this is the next turn of the same conversation,
  /// else start a fresh one. Returns the session and the text to send — only the
  /// new user turn on a continuation, the whole history when (re)starting.
  Future<({HermesAcpSession session, String text})> _sessionFor(
    NetworkCredential network,
    String model,
    String? conversationId,
    List<ChatMessage> history,
    String? workdir,
  ) async {
    // The folder is part of the key: moving a chat to another project must start
    // a fresh session, or the agent would keep reading the old folder.
    final root = workdir ?? _ref.read(agentWorkspaceDirProvider).path;
    final key = '${network.networkId}|$model|$conversationId|$root';
    final live = _live;
    final continues =
        live != null &&
        !live.session.isClosed &&
        live.key == key &&
        history.length > live.seen;

    if (continues) {
      live.seen = history.length;
      return (session: live.session, text: history.last.text.trim());
    }

    await live?.session.close();
    final service = _ref.read(hermesAcpServiceProvider)!;
    final session = await service.start(workdir: root);
    _live = _LiveSession(session: session, key: key, seen: history.length);
    // A fresh session has no context, so replay the history into the first turn.
    return (session: session, text: buildAgentPrompt(history));
  }

  /// Run one turn: stream the answer into the bubble as it arrives, mirror tool
  /// steps into the activity feed, and end with the finished reply.
  Stream<ChatSendUpdate> _runTurn(
    HermesAcpSession session,
    String text,
    String model,
  ) async* {
    final activityLog = _ref.read(agentActivityProvider.notifier)..clear();
    final log = _ref.read(commandLogProvider.notifier);
    final logId = log.begin(CliCallKind.start, 'hermes acp -m $model (agent)');

    final run = session.prompt(text);
    final answer = StringBuffer();
    var settled = false;
    try {
      await for (final event in run.events) {
        switch (event) {
          case HermesAcpActivity(:final activity):
            activityLog.upsert(activity);
          case HermesAcpMessage(:final text):
            answer.write(text);
            yield ChatSendStreaming(answer.toString());
        }
      }
      settled = true;
    } finally {
      // Only kill on an early exit (the stream was cancelled); a clean finish
      // must not tear down the session — the next turn reuses it.
      if (!settled) run.kill();
    }
    await run.done;

    final reply = answer.toString().trim();
    log.finish(logId, error: reply.isEmpty ? 'no output' : null);

    if (reply.isNotEmpty) {
      yield ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: reply));
      return;
    }
    yield const ChatSendFailure("The agent didn't return an answer.");
  }

  /// Ensure `~/.hermes` points at [network] with [model] (idempotent, only
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
    // Give the agent the grid's skills (image generation). Credential-free — the
    // skill reads the endpoint/key from the `.env` just written. A skill-install
    // hiccup must not block chatting, so its failure is swallowed here.
    try {
      await _ref.read(hermesSkillInstallerProvider).install();
    } on Object {
      // Non-fatal: the agent still chats, just without the image skill.
    }
    _ref.read(hermesConfiguredProvider.notifier).set(key);
    return null;
  }
}
