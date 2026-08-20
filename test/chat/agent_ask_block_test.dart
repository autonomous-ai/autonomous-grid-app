import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/commands/agent_ask_block.dart';
import 'package:grid_app/features/chat/logic/commands/chat_command.dart';

String _reply(String run) =>
    'Rõ rồi, tôi sẽ làm.\n\n```grid-ask\n{"run": "$run"}\n```';

void main() {
  group('an ask the assistant relayed', () {
    test('carries a repeat the app could not read out of the sentence — the '
        'reason this exists, since no phrase list covers "mày chạy ít nhất '
        'tới sáng mai"', () {
      final call = parseAgentAsk(_reply('/loop 45m research nguồn truyện mới'));

      expect(call?.command, ChatCommand.loop);
      expect(call?.argument, '45m research nguồn truyện mới');
    });

    test('carries a goal and a scheduled task too — one mechanism for the '
        'three things the app owns, rather than three phrase lists', () {
      expect(
        parseAgentAsk(_reply('/goal tests trong test/auth pass'))?.command,
        ChatCommand.goal,
      );
      expect(
        parseAgentAsk(_reply('/schedule mỗi sáng 8h tóm tắt hộp thư'))?.command,
        ChatCommand.schedule,
      );
    });

    test('takes the last block, so a reply that showed the format before '
        'using it acts on the one it settled on', () {
      const reply =
          'Ví dụ:\n```grid-ask\n{"run": "/loop 5m ví dụ"}\n```\n'
          'Thật:\n```grid-ask\n{"run": "/loop 2h việc thật"}\n```';

      expect(parseAgentAsk(reply)?.argument, '2h việc thật');
    });

    test('runs nothing outside the three — a reply that reached for /clear '
        'would be redecorating the room it was answering in', () {
      expect(parseAgentAsk(_reply('/clear')), isNull);
      expect(parseAgentAsk(_reply('/model qwen')), isNull);
    });

    test('a block that is not a command line does nothing, rather than '
        'something else', () {
      expect(parseAgentAsk(_reply('loop 45m no slash')), isNull);
      expect(parseAgentAsk('```grid-ask\nnot json at all\n```'), isNull);
      expect(parseAgentAsk('```grid-ask\n{"why": "thiếu run"}\n```'), isNull);
      expect(parseAgentAsk('một câu trả lời bình thường'), isNull);
    });

    test('the block comes off the reply once it has been acted on, so the '
        'transcript keeps the answer and none of the machinery', () {
      expect(stripAgentAsk(_reply('/loop 45m việc')), 'Rõ rồi, tôi sẽ làm.');
    });
  });
}
