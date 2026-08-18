import '../../playground/logic/chat_message.dart';
import 'conversation.dart';

/// What stands in the transcript where the answer to an interrupted turn should
/// be.
///
/// Written for two readers at once. The user, who otherwise sees their own
/// message sitting at the end of the chat with nothing after it and no way to
/// tell whether anything happened. And the next turn's model, which reads this
/// same transcript: told only "here is a prompt with no reply", it starts the
/// whole task again from nothing — which is exactly what a loop did on
/// 2026-08-18, planning the same work twice.
const String kInterruptedTurnNote =
    'No answer came back for this turn — the app closed, or it was stopped, '
    'before one arrived. Anything already done is on this computer rather than '
    'in this transcript, so check what is there before doing it again.';

/// Whether [chat]'s last turn never came back.
///
/// A turn lives in the running app: quit it, or lose it, while the agent is
/// working and no answer is ever written. The evidence is what the transcript
/// ends with — the user's own message, with nothing answering it.
///
/// A turn that *failed* or was stopped leaves the same shape, because the error
/// is live state and never reaches the file. That is why the note says no
/// answer came back rather than naming a cause it cannot check: from here the
/// three are one fact, and it is the fact that matters to the next turn.
bool wasTurnInterrupted(Conversation chat) =>
    chat.messages.isNotEmpty && chat.messages.last.role == ChatRole.user;

/// [chat] with [kInterruptedTurnNote] closing off the turn that never came
/// back.
///
/// Safe to run over a whole history: a chat this has already marked ends with
/// the note, so [wasTurnInterrupted] reads false and it is left alone.
Conversation markInterruptedTurn(Conversation chat) => chat.copyWith(
  messages: [
    ...chat.messages,
    const ChatMessage(role: ChatRole.assistant, text: kInterruptedTurnNote),
  ],
);
