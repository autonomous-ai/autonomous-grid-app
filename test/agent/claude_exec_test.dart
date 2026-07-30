import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/claude_chat_sender.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_app/infrastructure/cli/claude_exec_event.dart';
import 'package:grid_app/infrastructure/cli/claude_exec_service.dart';
import 'package:grid_app/infrastructure/cli/claude_stream_parser.dart';

/// One `stream_event` carrying a text delta — the shape the vendor's SSE arrives
/// in once `--include-partial-messages` is on.
Map<String, dynamic> _delta(String text) => {
  'type': 'stream_event',
  'event': {
    'type': 'content_block_delta',
    'index': 0,
    'delta': {'type': 'text_delta', 'text': text},
  },
};

/// One completed assistant content block.
Map<String, dynamic> _assistant(Map<String, dynamic> block) => {
  'type': 'assistant',
  'message': {
    'content': [block],
  },
};

Map<String, dynamic> _toolResult(String id, {bool failed = false}) => {
  'type': 'user',
  'message': {
    'content': [
      {'type': 'tool_result', 'tool_use_id': id, 'is_error': failed},
    ],
  },
};

/// Everything one call produced, since a single line can carry several blocks.
List<ClaudeExecEvent> _read(
  ClaudeStreamParser parser,
  Map<String, dynamic> line,
) => parser.read(line);

/// The single event a line produced, when the test expects exactly one.
ClaudeExecEvent _one(ClaudeStreamParser parser, Map<String, dynamic> line) =>
    _read(parser, line).single;

void main() {
  group('claudeExecArgs — a mistyped flag fails exactly like a mute model', () {
    test('a fresh turn asks for the streaming shape the parser reads', () {
      final args = claudeExecArgs(model: 'claude:sonnet');
      expect(args.first, '-p');
      // stream-json needs --verbose to emit anything at all, and partial
      // messages are what let the answer stream instead of landing in a lump.
      expect(args, containsAllInOrder(['--output-format', 'stream-json']));
      expect(args, contains('--verbose'));
      expect(args, contains('--include-partial-messages'));
      expect(args, containsAllInOrder(['--model', 'claude:sonnet']));
      expect(args, isNot(contains('--resume')));
    });

    test('a later turn resumes the session instead of replaying the chat', () {
      final args = claudeExecArgs(model: 'm', resumeSessionId: 'sess-1');
      expect(args, containsAllInOrder(['--resume', 'sess-1']));
    });

    test('the grant is the one named in kClaudePermissionMode, never an '
        'argv literal that could drift from it', () {
      expect(
        claudeExecArgs(model: 'm'),
        containsAllInOrder(['--permission-mode', kClaudePermissionMode]),
      );
    });
  });

  group('the claude -p stream, line by line', () {
    test('the opening init line carries the id to resume with later', () {
      final event = _one(ClaudeStreamParser(), {
        'type': 'system',
        'subtype': 'init',
        'session_id': 'abc-123',
      });
      expect(event, isA<ClaudeSessionStarted>());
      expect((event as ClaudeSessionStarted).sessionId, 'abc-123');
    });

    test('deltas build the answer, and the completed block replaces them — '
        'Claude reports one answer twice and it must not be counted twice', () {
      final parser = ClaudeStreamParser();
      expect((_one(parser, _delta('Hel')) as ClaudeMessageEvent).text, 'Hel');
      expect((_one(parser, _delta('lo')) as ClaudeMessageEvent).text, 'Hello');
      final whole = _one(
        parser,
        _assistant({'type': 'text', 'text': 'Hello there'}),
      );
      expect((whole as ClaudeMessageEvent).text, 'Hello there');
    });

    test('a second block joins the first — a turn can hold several', () {
      final parser = ClaudeStreamParser();
      _read(parser, _assistant({'type': 'text', 'text': 'First'}));
      final event = _one(
        parser,
        _assistant({'type': 'text', 'text': 'Second'}),
      );
      expect((event as ClaudeMessageEvent).text, 'First\n\nSecond');
    });

    test('a shell command reads as the command, not as the word "Bash"', () {
      final event = _one(
        ClaudeStreamParser(),
        _assistant({
          'type': 'tool_use',
          'id': 't1',
          'name': 'Bash',
          'input': {'command': 'ls -la'},
        }),
      );
      final activity = (event as ClaudeActivityEvent).activity;
      expect(activity.kind, AgentActivityKind.command);
      expect(activity.label, contains('ls -la'));
      expect(activity.status, AgentActivityStatus.running);
    });

    test('the result of a call updates the row it started, by id, so one step '
        'never appears twice', () {
      final parser = ClaudeStreamParser();
      _read(
        parser,
        _assistant({
          'type': 'tool_use',
          'id': 't1',
          'name': 'Bash',
          'input': {'command': 'ls'},
        }),
      );
      final done = _one(parser, _toolResult('t1'));
      final activity = (done as ClaudeActivityEvent).activity;
      expect(activity.id, 't1');
      expect(activity.status, AgentActivityStatus.done);
    });

    test('a tool that reported an error shows as failed, not quietly done', () {
      final parser = ClaudeStreamParser();
      _read(
        parser,
        _assistant({
          'type': 'tool_use',
          'id': 't1',
          'name': 'Bash',
          'input': {'command': 'nope'},
        }),
      );
      final done = _one(parser, _toolResult('t1', failed: true));
      expect(
        (done as ClaudeActivityEvent).activity.status,
        AgentActivityStatus.failed,
      );
    });

    test('the to-do tool is the plan, not a step — a "TodoWrite" row above the '
        'checklist it just produced says nothing', () {
      final events = _read(
        ClaudeStreamParser(),
        _assistant({
          'type': 'tool_use',
          'id': 't2',
          'name': 'TodoWrite',
          'input': {
            'todos': [
              {'content': 'Read the file', 'status': 'completed'},
              {'content': 'Write the fix', 'status': 'in_progress'},
            ],
          },
        }),
      );
      expect(events.single, isA<ClaudePlanEvent>());
      final plan = (events.single as ClaudePlanEvent).entries;
      expect(plan.map((e) => e.status), [
        AgentPlanStatus.done,
        AgentPlanStatus.active,
      ]);
      expect(plan.first.content, 'Read the file');
    });

    test('a write announces itself before it runs, which is the only moment '
        'the old contents still exist to diff against', () {
      final events = _read(
        ClaudeStreamParser(),
        _assistant({
          'type': 'tool_use',
          'id': 't3',
          'name': 'Write',
          'input': {'file_path': '/tmp/page.html', 'content': '<p>hi</p>'},
        }),
      );
      final started = events.whereType<ClaudeFileWriteStarted>().single;
      expect(started.callId, 't3');
      expect(started.path, '/tmp/page.html');
    });

    test('a write that failed changed nothing, so nothing is offered to open '
        'or undo', () {
      final parser = ClaudeStreamParser();
      _read(
        parser,
        _assistant({
          'type': 'tool_use',
          'id': 't3',
          'name': 'Write',
          'input': {'file_path': '/tmp/page.html'},
        }),
      );
      final events = _read(parser, _toolResult('t3', failed: true));
      expect(events.whereType<ClaudeFileWriteFinished>(), isEmpty);
    });

    test(
      'a read is not a write — only the file the agent changed is offered',
      () {
        final events = _read(
          ClaudeStreamParser(),
          _assistant({
            'type': 'tool_use',
            'id': 't4',
            'name': 'Read',
            'input': {'file_path': '/tmp/page.html'},
          }),
        );
        expect(events.whereType<ClaudeFileWriteStarted>(), isEmpty);
        expect(events.single, isA<ClaudeActivityEvent>());
      },
    );

    test('the result line is the answer and the end of the turn', () {
      final parser = ClaudeStreamParser();
      _read(parser, _delta('partial'));
      final events = _read(parser, {
        'type': 'result',
        'subtype': 'success',
        'is_error': false,
        'result': 'Done.',
      });
      expect((events.first as ClaudeMessageEvent).text, 'Done.');
      expect(events.last, isA<ClaudeTurnCompleted>());
    });

    test('a failed result ends the turn as a failure, never as an answer', () {
      final event = _one(ClaudeStreamParser(), {
        'type': 'result',
        'subtype': 'error_during_execution',
        'is_error': true,
        'result': 'API Error: 404 Not Found',
      });
      expect((event as ClaudeTurnFailed).message, contains('404'));
    });

    test('lines that carry nothing to show are skipped, so a newer build can '
        'add events without breaking the feed', () {
      final parser = ClaudeStreamParser();
      expect(
        _read(parser, {'type': 'system', 'subtype': 'thinking_tokens'}),
        isEmpty,
      );
      expect(_read(parser, {'type': 'rate_limit_event'}), isEmpty);
      expect(_read(parser, {'type': 'something_new'}), isEmpty);
    });
  });

  group('friendlyClaudeError', () {
    test('a relay with no Messages endpoint reads as the model, not as a '
        'stack trace — the grid-wide case never reaches here', () {
      expect(
        friendlyClaudeError('API Error: 404 {"detail":"Not Found"}'),
        kClaudeDialectFailure,
      );
    });

    test('an empty grid is a different problem with a different fix', () {
      expect(
        friendlyClaudeError('API Error: 503 No providers available'),
        kClaudeNoProviderFailure,
      );
    });

    test('anything else keeps Claude own last line, which at least says what '
        'it was doing', () {
      expect(
        friendlyClaudeError('Credit balance is too low'),
        contains('Credit balance is too low'),
      );
    });

    test('nothing to quote still gives the user a next step', () {
      expect(friendlyClaudeError('   '), contains('try again'));
    });
  });
}
