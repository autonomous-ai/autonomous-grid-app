import '../../../playground/logic/chat_message.dart';

/// Where a chat's context was summarized, and what the summary says.
///
/// Compacting does **not** throw the conversation away. Every message stays in
/// the file and on screen — what changes is only what the next turn *carries*:
/// the summary in place of the messages it covers, plus everything said since.
/// A chat you can no longer read is not a chat that saved you context, it is a
/// chat you lost.
class ChatCompaction {
  const ChatCompaction({
    required this.summary,
    required this.through,
    required this.at,
  });

  /// The assistant's summary of everything up to [through].
  final String summary;

  /// How many messages the summary stands in for — `messages[0 ..< through]`.
  /// Counted rather than indexed by id so a message added while the summary was
  /// being written is simply outside it, never half inside.
  final int through;

  final DateTime at;

  Map<String, Object?> toJson() => {
    'summary': summary,
    'through': through,
    'at': at.toUtc().toIso8601String(),
  };

  /// Null for anything this app didn't write — a chat with a half-written
  /// compaction opens as an ordinary chat, carrying its full history, which is
  /// the recoverable answer: it costs context, never content.
  static ChatCompaction? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final summary = '${raw['summary'] ?? ''}'.trim();
    final through = raw['through'];
    final at = DateTime.tryParse('${raw['at']}');
    if (summary.isEmpty || through is! int || through <= 0 || at == null) {
      return null;
    }
    return ChatCompaction(summary: summary, through: through, at: at);
  }
}

/// The messages a turn should actually carry, given what [compaction] covers.
///
/// Pure, and the one place that decides: the sender, the token estimate and any
/// test all ask this rather than re-deriving the slice.
///
/// A compaction that reaches past the end of the transcript covers all of it —
/// that is what a restored file describing a longer chat than this one means,
/// and dropping to the full history there would silently undo the compaction.
List<ChatMessage> historyForTurn(
  List<ChatMessage> messages,
  ChatCompaction? compaction,
) {
  if (compaction == null) return messages;
  final kept = compaction.through >= messages.length
      ? const <ChatMessage>[]
      : messages.sublist(compaction.through);
  return [
    ChatMessage(role: ChatRole.user, text: compactedPreamble(compaction)),
    ...kept,
  ];
}

/// How the summary is handed to the assistant.
///
/// As a user turn, not a system one: Grid drives four agents over four
/// transports and only some of them accept a system message inside a resumed
/// history. A user turn is the one shape all four are certain to carry.
String compactedPreamble(ChatCompaction compaction) =>
    'Here is a summary of everything we discussed earlier in this '
    'conversation, which has been compacted to save room:\n\n'
    '${compaction.summary}\n\n'
    'Carry on from there.';

/// What to ask the summarizer, given the transcript to fold up and the user's
/// own [focus] (`/compact only the API decisions`), which may be empty.
///
/// The instruction is deliberately about *continuing work*, not about writing a
/// nice précis: what this summary has to preserve is whatever the next turn
/// would otherwise have to scroll back for.
List<Map<String, String>> buildCompactMessages({
  required List<ChatMessage> messages,
  required String focus,
}) {
  final transcript = [
    for (final message in messages)
      if (message.text.trim().isNotEmpty)
        '${message.role == ChatRole.user ? 'User' : 'Assistant'}: '
            '${message.text.trim()}',
  ].join('\n\n');
  final focused = focus.trim().isEmpty
      ? ''
      : '\n\nThe user asked you to focus on: ${focus.trim()}';
  return [
    {
      'role': 'system',
      'content':
          'You summarize a conversation so that it can be continued without '
          'the original. Keep what the next turn needs: what the user asked '
          'for, decisions taken and why, file paths, commands, error messages, '
          'and anything still unfinished. Drop pleasantries and repetition. '
          'Write it as notes, not as a story, and do not address the user. '
          'Reply with the summary and nothing else.',
    },
    {
      'role': 'user',
      'content': 'Summarize this conversation:$focused\n\n$transcript',
    },
  ];
}

/// The line the chat shows where its context was folded up.
String compactedDividerLabel(ChatCompaction compaction) =>
    'Context compacted — the assistant continues from a summary of the '
    '${compaction.through} '
    '${compaction.through == 1 ? 'message' : 'messages'} above.';
