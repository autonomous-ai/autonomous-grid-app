import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/adapters/agent_turn_env.dart';

void main() {
  group('gridTurnEnv', () {
    test('empty when the chat has no conversation id yet', () {
      expect(gridTurnEnv(null), isEmpty);
      expect(gridTurnEnv(''), isEmpty);
    });

    test('carries the conversation id under the Grid chat id var', () {
      expect(gridTurnEnv('conv-1'), {kGridChatIdEnv: 'conv-1'});
    });
  });

  group('claudeConversationHeaderEnv', () {
    test('empty when the chat has no conversation id yet', () {
      expect(claudeConversationHeaderEnv(null), isEmpty);
      expect(claudeConversationHeaderEnv(''), isEmpty);
    });

    // The literal wire string, not a decode of whatever we encoded: Claude
    // Code splits this variable on its first `:` and takes what precedes it as
    // the header name, so a JSON value names a header `{"X-Grid-Conversation"`
    // and aborts the run before any request goes out. Only the exact line form
    // works, and only asserting it catches the day someone "tidies" it back.
    test('sets ANTHROPIC_CUSTOM_HEADERS to a literal Name: Value line', () {
      expect(claudeConversationHeaderEnv('conv-1'), {
        'ANTHROPIC_CUSTOM_HEADERS': 'X-Grid-Conversation: conv-1',
      });
    });
  });

  group('codexConversationHeaderOverrides', () {
    test('empty when the chat has no conversation id yet', () {
      expect(codexConversationHeaderOverrides(null), isEmpty);
      expect(codexConversationHeaderOverrides(''), isEmpty);
    });

    test('produces one http_headers override naming the conversation', () {
      final overrides = codexConversationHeaderOverrides('conv-1');
      expect(overrides, hasLength(1));
      expect(
        overrides.first,
        contains('http_headers.X-Grid-Conversation="conv-1"'),
      );
    });
  });
}
