import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/chat_transport.dart';
import '../../../infrastructure/cli/command_log.dart';
import '../../playground/logic/chat_message.dart';
import '../../playground/logic/one_shot_target.dart';
import 'chat_title.dart';

/// Asks a model what the chat turned out to be about, so the sidebar lists
/// subjects instead of the openings of requests.
///
/// The chat is already named by then — from the user's first line, cleaned by
/// [chatTitleFromLine] — and that name stands unless this comes back with
/// something. One blocking `chat/completions` call through the shared
/// [ChatTransport], at the same target as the commit-message writer and the
/// skill generator ([resolveOneShotTarget]): the local engine when one is
/// serving, else the grid's relay.
///
/// Every failure is answered with null rather than a message: nobody asked for a
/// name, so nobody may be told it couldn't be written. The chat simply keeps the
/// one it has.
class ChatTitleWriter {
  const ChatTitleWriter(this._ref);

  final Ref _ref;

  /// How much of a turn the model is shown. A name is decided by the opening
  /// lines, and sending a 40 KB transcript would blow a small local model's
  /// context window for the same five words.
  static const int _maxTurnChars = 700;

  /// Long enough for a slow local engine to answer five words, short enough that
  /// nothing is still pending when the user comes back to the sidebar. Naming a
  /// chat must never be something the app is left waiting on.
  static const Duration _timeout = Duration(seconds: 20);

  /// A name for the conversation [messages] opened with, or null when no model
  /// could answer.
  Future<String?> write(List<ChatMessage> messages) async {
    final excerpt = _excerpt(messages);
    if (excerpt.isEmpty) return null;

    final target = resolveOneShotTarget(_ref);
    if (target == null) return null;

    final prompt = _promptFor(excerpt);
    final log = _ref.read(commandLogProvider.notifier);
    final id = log.begin(
      CliCallKind.http,
      'POST ${target.endpoint}',
      detail: CommandDetail.json(
        chatCompletionsPayload(model: target.model, messages: prompt),
        authorized: target.apiKey.isNotEmpty,
      ),
    );
    final (reply, failure) = await _ref
        .read(chatTransportProvider)
        .complete(
          endpoint: target.endpoint,
          apiKey: target.apiKey,
          model: target.model,
          messages: prompt,
        )
        .timeout(
          _timeout,
          onTimeout: () => (null, const ChatTransportError('Timed out')),
        );
    log.finish(
      id,
      exitCode: failure?.statusCode ?? 200,
      error: failure?.message,
      responseBody: reply,
    );
    if (failure != null) return null;

    final title = tidyChatTitle(reply ?? '');
    return title.isEmpty ? null : title;
  }

  /// The opening exchange as the model reads it: what was asked, and the answer
  /// that says what the ask turned out to mean. Two turns rather than one
  /// because the ask alone is often the vague half ("study this link").
  ///
  /// Empty when there is nothing said yet — no call is worth making for it.
  String _excerpt(List<ChatMessage> messages) {
    final turns = <String>[];
    for (final message in messages) {
      final text = message.text.trim();
      if (text.isEmpty) continue;
      // Same reason as [deriveConversationTitle]: the opening exchange is what
      // the *user* asked, and a turn the app sent on their behalf would have the
      // model naming the chat after the app's own instruction.
      if (message.sentBy.isFromApp) continue;
      final who = message.role == ChatRole.user ? 'User' : 'Assistant';
      turns.add('$who: ${_trim(text)}');
      if (turns.length == 2) break;
    }
    return turns.join('\n\n');
  }

  /// A turn as far as the model gets to read it, with the cut named rather than
  /// silently applied.
  String _trim(String text) => text.length <= _maxTurnChars
      ? text
      : '${text.substring(0, _maxTurnChars)} […]';

  static List<Map<String, dynamic>> _promptFor(String excerpt) => [
    {
      'role': 'system',
      'content':
          'You name chat conversations for a sidebar. Read the exchange and '
          'reply with ONLY the name — no quotes, no code fence, no preamble.\n'
          '- At most 5 words and 40 characters, no full stop.\n'
          '- Name the subject, not the request: "Landing page copy", never '
          '"Help with the landing page".\n'
          '- Write it in the language the user wrote in.\n'
          'Never invent a subject the exchange does not show. If it shows no '
          'subject yet, name what was asked in as few words.',
    },
    {'role': 'user', 'content': excerpt},
  ];
}

/// Wire the writer through the container so the chat controller stays testable —
/// a fake transport swaps in without a live model.
final chatTitleWriterProvider = Provider<ChatTitleWriter>(ChatTitleWriter.new);
