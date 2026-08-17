import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/chat_transport.dart';
import '../../../infrastructure/cli/command_log.dart';
import '../../chat/logic/conversation.dart';
import '../../playground/logic/chat_message.dart';
import '../../playground/logic/one_shot_target.dart';

/// How much of the finished turn the model is shown.
///
/// A turn can be an hour of work; the answer wanted from it is four sentences.
/// What is read is the closing reply and the steps that led to it, and past a
/// few thousand characters of that the summary is decided by the first page
/// anyway — while a small local model would simply run out of context.
const int kPanelSummarySourceLimit = 6000;

/// How much of the summary reaches the panel.
///
/// The detail screen scrolls, but not far, and this rides the same 8192-byte
/// frame as everything else — a model that answers with an essay must not be
/// the reason a frame is refused.
const int kPanelSummaryLimit = 700;

/// Writes the long form of a turn's recap, for the panel's detail screen.
///
/// One blocking `chat/completions` call through the shared [ChatTransport], at
/// the same target as every other one-shot in the app ([resolveOneShotTarget]):
/// the local engine when one is serving, else the grid's relay.
///
/// It is deliberately *late* and deliberately *optional*. `turn.done` goes out
/// the moment the turn ends and never waits for this, because a tile spinning
/// on a summary is a tile lying about work that has finished — and a machine
/// with no model reachable simply never sends one, which the detail screen
/// reads as "nothing more to show".
class PanelSummaryWriter {
  const PanelSummaryWriter(this._ref);

  final Ref _ref;

  /// A few sentences on what just happened in [chat]. Exactly one half of the
  /// pair is non-null.
  Future<(String? text, String? error)> write(Conversation chat) async {
    final source = panelSummarySourceOf(chat);
    if (source.isEmpty) return (null, 'That turn left nothing to summarise.');

    final target = resolveOneShotTarget(_ref);
    if (target == null) return (null, noModelReady('write the summary'));

    final messages = _promptFor(source);
    final log = _ref.read(commandLogProvider.notifier);
    final id = log.begin(
      CliCallKind.http,
      'POST ${target.endpoint}',
      detail: CommandDetail.json(
        chatCompletionsPayload(model: target.model, messages: messages),
        authorized: target.apiKey.isNotEmpty,
      ),
    );
    final (reply, failure) = await _ref
        .read(chatTransportProvider)
        .complete(
          endpoint: target.endpoint,
          apiKey: target.apiKey,
          model: target.model,
          messages: messages,
        );
    // Nobody awaits this call, so the app can be quit in the middle of it and
    // the Debug tab's entry is no reason to fail on the way out.
    if (!_ref.mounted) return (null, 'Grid closed before the summary landed.');
    log.finish(
      id,
      exitCode: failure?.statusCode ?? 200,
      error: failure?.message,
      responseBody: reply,
    );

    if (failure != null) {
      return (null, friendlyOneShotError(failure, what: 'write the summary'));
    }
    final written = tidyPanelSummary(reply ?? '');
    if (written.isEmpty) {
      return (null, "The model didn't answer with a summary.");
    }
    return (written, null);
  }

  static List<Map<String, dynamic>> _promptFor(String turn) => [
    {
      'role': 'system',
      'content':
          'You explain what an assistant just did, for someone reading a '
          'small round screen across the room. Reply with ONLY the '
          'explanation — no heading, no markdown, no bullet points.\n'
          '- Two to four short sentences, plain language, past tense.\n'
          '- Say what was done and how it came out. Name a file or a command '
          'only when it is the point.\n'
          "- If the work stopped part-way, say so.\n"
          'Never invent anything the turn does not show.',
    },
    {'role': 'user', 'content': turn},
  ];
}

/// Wired through the container so the panel stays testable — a fake transport
/// swaps in without a live model.
final panelSummaryWriterProvider = Provider<PanelSummaryWriter>(
  (ref) => PanelSummaryWriter(ref),
);

/// What the model is asked to summarise: the last thing the assistant said in
/// [chat] and the steps it ran to get there.
///
/// Read off the transcript rather than the live run feed, because by the time a
/// turn has ended the feed has done its job and the message is what survives —
/// including, for a turn that was cut off, the steps left `unknown`, which are
/// half the account of what happened.
///
/// Pure, so what the model is shown can be checked without a model.
String panelSummarySourceOf(Conversation chat) {
  for (final message in chat.messages.reversed) {
    if (message.role != ChatRole.assistant) continue;
    final said = message.text.trim();
    final steps = [
      for (final part in message.parts)
        if (part is TurnStep)
          '- ${part.step.label.trim()} [${part.step.status.name}]',
    ];
    if (said.isEmpty && steps.isEmpty) continue;
    final buffer = StringBuffer();
    if (steps.isNotEmpty) {
      buffer.writeln('Steps it ran:\n${steps.join('\n')}\n');
    }
    if (said.isNotEmpty) buffer.write('What it said:\n$said');
    return _trim(buffer.toString().trim());
  }
  return '';
}

/// Takes what the model said back to something a 466px screen can draw: no
/// fence, no lead-in, no heading, and short enough to arrive.
String tidyPanelSummary(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return '';
  if (text.startsWith('```')) {
    final firstBreak = text.indexOf('\n');
    final end = text.lastIndexOf('```');
    if (firstBreak != -1) {
      text =
          (end > firstBreak
                  ? text.substring(firstBreak + 1, end)
                  : text.substring(firstBreak + 1))
              .trim();
    }
  }
  if (text.length <= kPanelSummaryLimit) return text;
  // Never cut a character in half — this is about to be encoded as UTF-8.
  final unit = text.codeUnitAt(kPanelSummaryLimit - 1);
  final end = (unit >= 0xD800 && unit <= 0xDBFF)
      ? kPanelSummaryLimit - 1
      : kPanelSummaryLimit;
  return '${text.substring(0, end)}…';
}

/// The turn as far as the model gets to read it, with the cut named rather than
/// silently applied (§9).
String _trim(String turn) {
  if (turn.length <= kPanelSummarySourceLimit) return turn;
  return '${turn.substring(0, kPanelSummarySourceLimit)}\n'
      '[… the rest of this turn is not shown]';
}
