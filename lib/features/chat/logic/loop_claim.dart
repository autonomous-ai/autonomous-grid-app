import '../../playground/logic/chat_message.dart';
import 'commands/chat_loop.dart';
import 'commands/loop_pace_block.dart';
import 'conversation.dart';

/// The note the app adds under a reply that says it set a repeat, when nothing
/// is repeating.
///
/// An agent asked to keep doing something reaches for the `grid-loop` block,
/// because that is the only repeating thing it has ever been told about — and
/// the block cannot *start* a loop: it is read at the end of a beat of one
/// already running, and nowhere else. So on 2026-08-19 an answer ended
/// "I've set a grid-loop to re-invoke every hour" over a chat whose loop had
/// been stopped since the day before, and the night's work never happened.
///
/// The card now tells every agent that, but a card is an instruction and this
/// is a guarantee: whatever the assistant believes it did, the chat says what
/// actually runs.
const String kUnbackedLoopClaimNote =
    'That reply set up a repeat, but nothing is repeating in this chat — a '
    '`grid-loop` block only paces a repeat that has already started. To repeat '
    'this while Grid is open, type `/loop ` and what you want repeated. For '
    'work that has to keep going after Grid is closed, ask for it to be '
    'scheduled instead.';

/// Whether [reply] carries a `grid-loop` block while [loop] is not running.
///
/// Uses the loop's own parser rather than looking for the fence: a block the
/// app could not read is one it would not have acted on either, so noting it
/// would report a promise the assistant never actually made.
bool claimsLoopWithoutOne(String reply, ChatLoop? loop) =>
    !(loop?.isRunning ?? false) && parseLoopPaceBlock(reply) != null;

/// [message] with its `grid-loop` blocks gone from the text *and* the parts.
///
/// Both, or the block disappears from the stored answer and stays on screen:
/// the rendered reply is built from [ChatMessage.parts], and the text is what
/// is saved, re-sent as history and exported.
ChatMessage withoutLoopBlock(ChatMessage message) => message.copyWith(
  text: stripLoopPaceBlock(message.text),
  parts: [
    for (final part in message.parts)
      part is TurnText ? TurnText(stripLoopPaceBlock(part.text)) : part,
  ],
);

/// [chat] with the unbacked block taken off its last reply and
/// [kUnbackedLoopClaimNote] after it, or [chat] unchanged when the last reply
/// makes no such claim.
Conversation noteUnbackedLoopClaim(Conversation chat) {
  final messages = [...chat.messages];
  final last = messages.lastIndexWhere((m) => m.role == ChatRole.assistant);
  if (last == -1) return chat;
  if (!claimsLoopWithoutOne(messages[last].text, chat.loop)) return chat;
  messages[last] = withoutLoopBlock(messages[last]);
  messages.add(
    const ChatMessage(role: ChatRole.assistant, text: kUnbackedLoopClaimNote),
  );
  return chat.copyWith(messages: messages);
}
