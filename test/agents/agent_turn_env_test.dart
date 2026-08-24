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

  group('per-turn X-Request-Id headers', () {
    test('empty when no turn id is named', () {
      expect(gridTurnEnv('conv-1', turnId: null), {kGridChatIdEnv: 'conv-1'});
    });

    // Both CLI lanes receive the turn's X-Request-Id as a literal `Name: Value`
    // header line (Claude Code reads ANTHROPIC_CUSTOM_HEADERS, Codex reads
    // OPENAI_CUSTOM_HEADERS) so every relay call of this turn is grouped under
    // one id. Only the exact line form works — each CLI splits on the first
    // `:` and takes what precedes it as the header name.
    test('sets both custom-header vars to a literal X-Request-Id: <id> line',
        () {
      expect(
        gridTurnEnv('conv-1', turnId: 'turn-1'),
        {
          'ANTHROPIC_CUSTOM_HEADERS': 'X-Request-Id: turn-1',
          'OPENAI_CUSTOM_HEADERS': 'X-Request-Id: turn-1',
          kGridChatIdEnv: 'conv-1',
        },
      );
    });

    test('the header value is the raw id, never JSON or quotes', () {
      final env = gridTurnEnv(null, turnId: 'abc-123');
      expect(env['ANTHROPIC_CUSTOM_HEADERS'], 'X-Request-Id: abc-123');
      expect(env['OPENAI_CUSTOM_HEADERS'], 'X-Request-Id: abc-123');
    });
  });
}
