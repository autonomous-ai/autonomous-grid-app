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

  group('a repeat the user asked for in words the app could not read', () {
    const block =
        '```grid-loop\n'
        '{"start": true, "next": "45m", "why": "quét lại tới sáng"}\n'
        '```';

    test('is read off the reply, because the assistant read the sentence the '
        'app could not — and that turn was happening anyway', () {
      final asked = loopStartAskedFor('Rõ rồi.\n$block', null);

      expect(asked?.next, const Duration(minutes: 45));
      expect(asked?.why, 'quét lại tới sáng');
    });

    test('is not also scolded — the note is for the other kind of block, and '
        'saying both would be the app arguing with itself', () {
      expect(claimsLoopWithoutOne('Rõ rồi.\n$block', null), isFalse);
    });

    test('never restarts a loop the user stopped: a chat that has a loop at '
        'all is one the app already knows the answer for', () {
      expect(loopStartAskedFor('Rõ rồi.\n$block', _loop(LoopStatus.running)), isNull);
    });

    test('with no gap in it starts nothing — a repeat firing on an interval '
        'nobody chose is a task scheduled at an hour nobody chose', () {
      const gapless = '```grid-loop\n{"start": true, "why": "tới sáng"}\n```';

      expect(loopStartAskedFor('Rõ.\n$gapless', null), isNull);
      expect(
        claimsLoopWithoutOne('Rõ.\n$gapless', null),
        isTrue,
        reason: 'it still claimed a repeat, so the note still belongs',
      );
    });

    test('a pacing block is not a start: the two are told apart by the word, '
        'not by which chat they landed in', () {
      const pacing = '```grid-loop\n{"next": "20m", "why": "chờ build"}\n```';

      expect(loopStartAskedFor('Xong.\n$pacing', null), isNull);
    });

    test('the block comes off the reply once it has been acted on, so the '
        'transcript keeps the answer and none of the machinery', () {
      final chat = withoutLoopBlockOnLastReply(_chat(reply: 'Rõ rồi.\n$block'));

      expect(chat.messages.last.text, 'Rõ rồi.');
      expect(chat.messages.last.text, isNot(contains('grid-loop')));
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
