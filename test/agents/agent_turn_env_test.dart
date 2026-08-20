import 'dart:convert';

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

    test('sets ANTHROPIC_CUSTOM_HEADERS with the conversation id', () {
      final env = claudeConversationHeaderEnv('conv-1');
      expect(env, contains('ANTHROPIC_CUSTOM_HEADERS'));
      final decoded =
          jsonDecode(env['ANTHROPIC_CUSTOM_HEADERS']!) as Map<String, Object?>;
      expect(decoded['X-Grid-Conversation'], 'conv-1');
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
