import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/import/claude_session_parser.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';

/// One line of a Claude Code session file, stamped so the import has a date.
String _line(String type, Object content) => jsonEncode({
  'type': type,
  'timestamp': '2026-09-01T10:00:00Z',
  'message': {'role': type, 'content': content},
});

void main() {
  group('an imported Claude session is what was said and done, not what the '
      'CLI wrote for the model', () {
    test('the note that the person pressed Stop is not put in their mouth — '
        'it arrives in their turn, as if they had typed it', () {
      final session = parseClaudeSession(
        sessionId: 's1',
        lines: [
          _line('user', 'Fix the tests'),
          _line('assistant', [
            {'type': 'text', 'text': 'On it.'},
          ]),
          _line('user', [
            {'type': 'text', 'text': '[Request interrupted by user]'},
          ]),
        ],
      );
      expect(
        [
          for (final message in session!.messages)
            if (message.role == ChatRole.user) message.text,
        ],
        ['Fix the tests'],
      );
    });

    test('a step keeps what its tool said, without the tags the CLI wraps '
        'round it — the same reader the live feed uses', () {
      final session = parseClaudeSession(
        sessionId: 's1',
        lines: [
          _line('user', 'Change a.dart'),
          _line('assistant', [
            {
              'type': 'tool_use',
              'id': 't1',
              'name': 'Edit',
              'input': {
                'file_path': '/r/a.dart',
                'old_string': 'a',
                'new_string': 'b',
              },
            },
          ]),
          _line('user', [
            {
              'type': 'tool_result',
              'tool_use_id': 't1',
              'is_error': true,
              'content':
                  '<tool_use_error>File has not been read yet.</tool_use_error>',
            },
          ]),
        ],
      );
      final step = stepsOf(session!.messages.last.parts).single;
      expect(step.status, AgentActivityStatus.failed);
      expect(step.result, 'File has not been read yet.');
    });
  });
}
