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

/// Whether [reply] carries a `grid-loop` block in a chat that has no loop.
///
/// **No loop at all**, not "no loop running": a chat whose loop the user
/// stopped mid-turn gets the block from the beat that was already in flight,
/// and blaming the assistant for it would be the app telling the user off for
/// its own timing. The reading that matters is the one this note was written
/// for — an assistant deciding by itself to repeat something, in a chat where
/// repeating was never set up.
///
/// Uses the loop's own parser rather than looking for the fence: a block the
/// app could not read is one it would not have acted on either, so noting it
/// would report a promise the assistant never actually made.
bool claimsLoopWithoutOne(String reply, ChatLoop? loop) =>
    loop == null &&
    parseLoopPaceBlock(reply) != null &&
    loopStartAskedFor(reply, loop) == null;

/// The repeat the assistant says the user asked for, or null when the reply
/// asks for none.
///
/// The half of this file that *starts* something rather than refusing to. The
/// app reads a command out of a sentence deterministically, which is right for
/// "lặp lại mỗi 30 phút" — a closed set of words, no round-trip, same answer
/// twice. It is hopeless for the other half of how people ask: "mày chạy ít
/// nhất tới sáng mai tao vào để kiểm tra" carries no word this app owns, and no
/// list of phrases will ever cover the next one. The assistant has already read
/// that sentence by the time it answers, so it is asked to say so in the block
/// it already knows — and the turn it rides was happening anyway.
///
/// Three things keep this from becoming an agent that loops itself:
/// - only a block that says `start`, which the card asks for **only** when the
///   user asked for a repeat;
/// - only in a chat with no loop, so it can never restart one the user stopped;
/// - and the loop's prompt is the **user's own message**, never the reply — an
///   assistant that starts one unasked still repeats the words the person
///   typed, in a bar that names it and stops on one word.
///
/// The gap has to be in the block. A repeat firing on an interval nobody chose
/// is the schedule-with-no-hour mistake wearing another hat, so a `start` with
/// no readable `next` falls through to [kUnbackedLoopClaimNote] instead.
LoopPace? loopStartAskedFor(String reply, ChatLoop? loop) {
  if (loop != null) return null;
  final block = parseLoopPaceBlock(reply);
  if (block == null || !block.start || block.next == null) return null;
  return block;
}

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

/// [chat] with the `grid-loop` block taken off its last reply, and nothing else
/// changed.
///
/// The block is how the assistant talks to the app; once the app has acted on
/// it, leaving it in the transcript shows the user a line of JSON they never
/// asked to read — and re-sends it as history on every turn after.
Conversation withoutLoopBlockOnLastReply(Conversation chat) {
  final messages = [...chat.messages];
  final last = messages.lastIndexWhere((m) => m.role == ChatRole.assistant);
  if (last == -1) return chat;
  messages[last] = withoutLoopBlock(messages[last]);
  return chat.copyWith(messages: messages);
}

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
