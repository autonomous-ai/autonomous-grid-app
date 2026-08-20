import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/commands/chat_loop.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/chat/logic/loop_claim.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';

const String _claim =
    'I will keep researching overnight.\n\n'
    '```grid-loop\n{"next": "1h", "why": "carry on until morning"}\n```';

ChatLoop _loop(LoopStatus status) => ChatLoop(
  prompt: 'research the sources',
  interval: const Duration(hours: 1),
  startedAt: DateTime(2026, 8, 18, 15),
  nextAt: DateTime(2026, 8, 19, 15),
  status: status,
  iterations: 1,
);

Conversation _chat({required String reply, ChatLoop? loop}) => Conversation(
  id: '1',
  title: 'research',
  model: 'm',
  createdAt: DateTime(2026, 8, 18),
  updatedAt: DateTime(2026, 8, 19),
  loop: loop,
  messages: [
    const ChatMessage(role: ChatRole.user, text: 'keep going overnight'),
    ChatMessage(role: ChatRole.assistant, text: reply),
  ],
);

void main() {
  group('an answer that sets up a repeat nothing is running', () {
    test('is corrected in the chat, because the user reads the promise and not '
        'the loop bar', () {
      final noted = noteUnbackedLoopClaim(_chat(reply: _claim));

      expect(noted.messages.last.text, kUnbackedLoopClaimNote);
      expect(noted.messages, hasLength(3));
    });

    test('loses the block it wrote — left in, the answer ends with the JSON '
        'the app never read', () {
      final noted = noteUnbackedLoopClaim(_chat(reply: _claim));

      expect(noted.messages[1].text, isNot(contains('grid-loop')));
      expect(noted.messages[1].text, startsWith('I will keep researching'));
    });

    test('is a chat that never had a loop — a chat whose loop was stopped '
        'mid-beat gets that beat\'s block, and blaming the assistant for it '
        'would be the app telling the user off for its own timing', () {
      final stopped = _chat(reply: _claim, loop: _loop(LoopStatus.stopped));

      expect(identical(noteUnbackedLoopClaim(stopped), stopped), isTrue);
      expect(
        noteUnbackedLoopClaim(_chat(reply: _claim)).messages.last.text,
        kUnbackedLoopClaimNote,
      );
    });
  });

  group('an answer the app will act on', () {
    test('is left alone while the loop runs — that block is the loop pacing '
        'itself, and the beat strips it', () {
      final chat = _chat(reply: _claim, loop: _loop(LoopStatus.running));

      expect(identical(noteUnbackedLoopClaim(chat), chat), isTrue);
    });

    test('an ordinary reply with no block is untouched, so the note never '
        'lands on a turn that promised nothing', () {
      final chat = _chat(reply: 'Done — the build passed.');

      expect(identical(noteUnbackedLoopClaim(chat), chat), isTrue);
    });

    test('an unreadable block promises nothing the app could have acted on, so '
        'it is not corrected either', () {
      final chat = _chat(
        reply: 'Carrying on.\n\n```grid-loop\nevery hour, boss\n```',
      );

      expect(identical(noteUnbackedLoopClaim(chat), chat), isTrue);
    });
  });
}
