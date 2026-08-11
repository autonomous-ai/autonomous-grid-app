import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_app/infrastructure/cli/pi_exec_service.dart';

/// One assistant round that ended on [error], as `pi --mode json` writes it.
Map<String, dynamic> _failedRound(String error) => {
  'type': 'message_end',
  'message': {
    'role': 'assistant',
    'stopReason': 'error',
    'errorMessage': error,
    'content': <dynamic>[],
  },
};

/// One assistant round that answered.
Map<String, dynamic> _answeredRound(String text) => {
  'type': 'message_end',
  'message': {
    'role': 'assistant',
    'stopReason': 'stop',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
};

void main() {
  group('piExecArgs — the pi --mode json invocation', () {
    test(
      'a fresh turn streams JSON, declines the folder it opens in, and names '
      'the grid model',
      () {
        // A wrong flag fails exactly like a model that wouldn't answer, so the
        // argv is pinned here rather than trusted by eye.
        expect(piExecArgs(model: 'qwen3'), [
          '--mode',
          'json',
          '--no-approve',
          '--model',
          'grid/qwen3',
        ]);
      },
    );

    test(
      'resuming adds --session and takes no other subcommand — unlike Codex',
      () {
        expect(piExecArgs(model: 'qwen3', resumeSessionId: 'sess-1'), [
          '--mode',
          'json',
          '--no-approve',
          '--model',
          'grid/qwen3',
          '--session',
          'sess-1',
        ]);
      },
    );

    test(
      'a model id keeps its own punctuation — pi resolves provider/id, and a '
      'colon in the id is part of the id',
      () {
        expect(
          piExecArgs(model: 'qwen3-coder:30b'),
          contains('grid/qwen3-coder:30b'),
        );
      },
    );
  });

  group('parsePiEvent — the pi --mode json stream', () {
    test('the first session line carries the id to resume with later', () {
      final event = parsePiEvent({
        'type': 'session',
        'version': 3,
        'id': 'abc-123',
        'cwd': '/x',
      }, PiTurnState());
      expect(event, isA<PiSessionStarted>());
      expect((event as PiSessionStarted).sessionId, 'abc-123');
    });

    test('streamed text deltas assemble the answer so far', () {
      final state = PiTurnState();
      parsePiEvent({
        'type': 'message_start',
        'message': {'role': 'assistant', 'content': <dynamic>[]},
      }, state);
      final first = parsePiEvent({
        'type': 'message_update',
        'assistantMessageEvent': {
          'type': 'text_delta',
          'contentIndex': 0,
          'delta': 'Hello',
        },
      }, state);
      expect((first as PiMessageEvent).text, 'Hello');
      final second = parsePiEvent({
        'type': 'message_update',
        'assistantMessageEvent': {
          'type': 'text_delta',
          'contentIndex': 0,
          'delta': ' world',
        },
      }, state);
      expect((second as PiMessageEvent).text, 'Hello world');
    });

    test('message_end carries the authoritative text — a build with no deltas '
        'still shows an answer', () {
      final state = PiTurnState();
      final event = parsePiEvent(_answeredRound('The answer.'), state);
      expect((event as PiMessageEvent).text, 'The answer.');
    });
  });

  group('parsePiEvent — a failed round is not a failed turn', () {
    test('a round that stopped on an error says nothing yet: pi retries it '
        'itself, and the chat must not be told the turn is over', () {
      final state = PiTurnState();
      expect(parsePiEvent(_failedRound('Connection error.'), state), isNull);
      expect(state.pendingError, 'Connection error.');
    });

    test('the answer a retry produced is the turn: the first attempt\'s error '
        'never reaches the chat', () {
      final state = PiTurnState();
      parsePiEvent(_failedRound('Connection error.'), state);
      parsePiEvent({'type': 'auto_retry_start', 'attempt': 1}, state);
      final answer = parsePiEvent(_answeredRound('Here you go.'), state);
      expect((answer as PiMessageEvent).text, 'Here you go.');

      expect(
        parsePiEvent({'type': 'agent_settled'}, state),
        isA<PiTurnCompleted>(),
      );
    });

    test(
      'an exchange whose every attempt failed reports the last reason, once, '
      'when it settles',
      () {
        final state = PiTurnState();
        parsePiEvent(_failedRound('Connection error.'), state);
        parsePiEvent(_failedRound('HTTP 503: no providers'), state);
        final settled = parsePiEvent({'type': 'agent_settled'}, state);
        expect((settled as PiTurnFailed).message, 'HTTP 503: no providers');
      },
    );

    test('agent_end closes one attempt, not the exchange — only agent_settled '
        'ends it', () {
      final state = PiTurnState();
      expect(
        parsePiEvent({
          'type': 'agent_end',
          'messages': <dynamic>[],
          'willRetry': true,
        }, state),
        isNull,
      );
      expect(parsePiEvent({'type': 'turn_end', 'message': {}}, state), isNull);
      expect(
        parsePiEvent({'type': 'agent_settled'}, state),
        isA<PiTurnCompleted>(),
      );
    });
  });

  group('parsePiEvent — tool calls', () {
    test('a bash tool call maps to a command activity, running then done under '
        'the same id', () {
      final state = PiTurnState();
      final started = parsePiEvent({
        'type': 'tool_execution_start',
        'toolCallId': 't1',
        'toolName': 'bash',
        'args': {'command': 'ls -la'},
      }, state);
      final startActivity = (started as PiActivityEvent).activity;
      expect(startActivity.kind, AgentActivityKind.command);
      expect(startActivity.label, 'ls -la');
      expect(startActivity.status, AgentActivityStatus.running);

      final ended = parsePiEvent({
        'type': 'tool_execution_end',
        'toolCallId': 't1',
        'toolName': 'bash',
        'result': 'total 0',
        'isError': false,
      }, state);
      final endActivity = (ended as PiActivityEvent).activity;
      expect(endActivity.id, 't1');
      expect(endActivity.status, AgentActivityStatus.done);
    });

    test('a failed tool call reads as failed, not done', () {
      final state = PiTurnState();
      parsePiEvent({
        'type': 'tool_execution_start',
        'toolCallId': 't2',
        'toolName': 'grep',
        'args': <String, dynamic>{},
      }, state);
      final ended = parsePiEvent({
        'type': 'tool_execution_end',
        'toolCallId': 't2',
        'toolName': 'grep',
        'isError': true,
      }, state);
      expect(
        (ended as PiActivityEvent).activity.status,
        AgentActivityStatus.failed,
      );
    });

    test('a completed write is offered to the chat to open, by the path it '
        'opened with', () {
      final state = PiTurnState();
      parsePiEvent({
        'type': 'tool_execution_start',
        'toolCallId': 'w1',
        'toolName': 'write',
        'args': {'path': '/tmp/page.html', 'content': '<html>'},
      }, state);
      final ended = parsePiEvent({
        'type': 'tool_execution_end',
        'toolCallId': 'w1',
        'toolName': 'write',
        'isError': false,
      }, state);
      expect(ended, isA<PiFileChangeEvent>());
      expect((ended as PiFileChangeEvent).paths, ['/tmp/page.html']);
    });

    test('a tool name this build has never heard of still shows a readable row '
        'rather than nothing', () {
      final event = parsePiEvent({
        'type': 'tool_execution_start',
        'toolCallId': 'x1',
        'toolName': 'summarise',
        'args': <String, dynamic>{},
      }, PiTurnState());
      final activity = (event as PiActivityEvent).activity;
      expect(activity.label, 'Summarise');
      expect(activity.kind, AgentActivityKind.tool);
    });
  });
}
