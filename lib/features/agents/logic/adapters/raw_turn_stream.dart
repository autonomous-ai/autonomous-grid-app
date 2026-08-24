import 'dart:async';

import '../../../../infrastructure/cli/command_log.dart';
import '../../../../infrastructure/cli/raw_agent_service.dart';
import '../../../playground/logic/chat_message.dart';
import '../../../playground/logic/chat_sender.dart';
import '../agent_server_error.dart';

/// The line to show for a raw turn that is over, or null when it answered.
///
/// Pure, so the one decision every agent shares — did this turn produce
/// something to show, and if not, what does the user read instead — is written
/// once and tested, rather than restated per sender.
///
/// The agent's own words win wherever there are any: a turn that failed *after*
/// starting reports itself, and that report is the failure line. The app writes
/// a sentence only in the two cases where the agent said nothing at all — it
/// never started, or it exited in silence.
String? rawTurnFailure({
  required String output,
  required int exitCode,
  required String agentName,
  String? startFailure,
}) {
  if (startFailure != null) {
    return "Couldn't start $agentName on this computer. $startFailure";
  }
  if (exitCode != 0) {
    return output.isEmpty
        ? '$agentName stopped without saying why (exit code $exitCode).'
        : output;
  }
  return output.isEmpty ? kAgentNoAnswer : null;
}

/// Feeds one raw agent turn into the chat exactly as the CLI printed it.
///
/// The whole reply is re-sent on every chunk ([ChatSendStreaming] is cumulative),
/// so the bubble fills as the agent writes. Nothing is parsed on the way through:
/// what the user reads is stdout and stderr in arrival order, which is the point
/// of this lane and also everything it can offer — there are no steps, no plan
/// and no permission cards to raise, because none of them survive outside the
/// JSON the app no longer asks for.
///
/// Driven by an explicit subscription (not `await for`) so Stop tears the turn
/// down there and then: cancelling the returned stream kills the process.
Stream<ChatSendUpdate> streamRawAgentTurn({
  required RawAgentRun run,
  required CommandLogNotifier log,
  required int logId,
  required String agentName,
}) {
  final answer = StringBuffer();
  final updates = StreamController<ChatSendUpdate>();
  String? startFailure;
  var settled = false;

  final output = run.output.listen(
    (chunk) {
      answer.write(chunk);
      updates.add(ChatSendStreaming(answer.toString()));
    },
    // The only error this stream carries is the app's own: a CLI that never
    // started. Held rather than shown now, so the terminal update below stays
    // the single place a turn reports how it went.
    onError: (Object error) {
      startFailure = error is RawAgentException ? error.message : '$error';
    },
    onDone: () async {
      final exitCode = await run.done;
      settled = true;
      final raw = answer.toString().trim();
      final failure = rawTurnFailure(
        output: raw,
        exitCode: exitCode,
        agentName: agentName,
        startFailure: startFailure,
      );
      log.finish(logId, exitCode: exitCode, error: failure);
      updates.add(
        failure != null
            ? ChatSendFailure(failure)
            : ChatSendSuccess(ChatMessage(role: ChatRole.assistant, text: raw)),
      );
      await updates.close();
    },
  );

  // The user hit Stop, or left the chat. A clean finish also lands here via the
  // done above (with [settled] set) and must not re-kill anything.
  updates.onCancel = () async {
    await output.cancel();
    if (settled) return;
    run.kill();
    log.finish(logId, error: 'stopped');
  };
  return updates.stream;
}
