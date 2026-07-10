import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/codex_event.dart';
import '../../../infrastructure/cli/command_log.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../playground/logic/chat_message.dart';
import '../../playground/logic/chat_sender.dart';
import '../../playground/logic/playground_request.dart';
import 'agent_prompt.dart';
import 'codex_exec_args.dart';
import 'codex_providers.dart';

/// The Agent-mode [ChatSender]: routes a Chat-tab turn through `codex exec`
/// instead of the normal chat relay, so the reply comes from the codex agent
/// loop (read-only sandbox) driven by the selected grid model.
///
/// It implements the same [ChatSender] interface as the default relay sender, so
/// the Chat controller swaps between them on the Agent toggle without any other
/// change. Stateless per send today — the full transcript rides in the prompt;
/// `codex exec resume` session continuity is a follow-up once the sender can see
/// a conversation id.
final codexChatSenderProvider = Provider<ChatSender>(
  (ref) => CodexChatSender(ref),
);

class CodexChatSender implements ChatSender {
  CodexChatSender(this._ref);

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
    final service = _ref.read(codexAgentServiceProvider);
    if (service == null) {
      yield const ChatSendFailure(
        "Codex isn't installed for Agent mode. Turn Agent off and on again to "
        'install it.',
      );
      return;
    }
    final prompt = buildAgentPrompt(history);
    if (prompt.isEmpty) {
      yield const ChatSendFailure('Nothing to send.');
      return;
    }

    final built = buildCodexExecArgs(
      network: network,
      model: model,
      prompt: prompt,
    );
    final workdir = _ref.read(agentWorkspaceDirProvider).path;
    final log = _ref.read(commandLogProvider.notifier);
    final logId = log.begin(CliCallKind.start, 'codex exec -m $model (agent)');
    final activityLog = _ref.read(codexActivityProvider.notifier)..clear();

    final run = service.exec(
      args: built.args,
      environment: built.env,
      workdir: workdir,
    );

    final answer = StringBuffer();
    String? failure;
    var settled = false;
    try {
      await for (final event in run.events) {
        switch (event) {
          case CodexActivityUpdate(:final activity):
            activityLog.upsert(activity);
          case CodexAgentMessage(:final text):
            if (answer.isNotEmpty) answer.write('\n\n');
            answer.write(text);
          case CodexTurnFailed(:final message):
            failure = message;
          case CodexStreamError(:final message):
            // Transient reconnects and the final error share this type; keep the
            // latest so a genuine failure survives while a recovered blip is
            // overwritten by success (answer non-empty wins below).
            failure = message;
          case CodexThreadStarted():
          case CodexTurnStarted():
          case CodexTurnCompleted():
          case CodexItemError():
          case CodexUnknownEvent():
            break;
        }
      }
      settled = true;
    } finally {
      if (!settled) run.kill();
    }

    final exit = await run.exitCode;
    final text = answer.toString().trim();
    log.finish(logId, exitCode: exit, error: text.isEmpty ? failure : null);

    if (text.isNotEmpty) {
      yield ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: text));
      return;
    }
    yield ChatSendFailure(_humanize(failure, exit));
  }

  /// Maps a raw codex/stderr failure to a plain-language line. The most common
  /// one right now is the relay missing `/v1/responses` (pending backend) — call
  /// it out honestly instead of leaking a 404. Raw detail stays in the log.
  static String _humanize(String? raw, int exit) {
    final message = raw ?? '';
    if (message.contains('/responses') ||
        message.contains('404') ||
        message.contains('Not Found')) {
      return "This grid doesn't support Agent mode yet (waiting on a backend "
          'update). For now, turn Agent off to chat normally.';
    }
    if (message.trim().isNotEmpty) return message.trim();
    return "The agent didn't respond (exit code $exit).";
  }
}
