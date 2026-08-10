import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_app/infrastructure/cli/pi_exec_service.dart';

void main() {
  group('piExecArgs — the pi --mode json invocation', () {
    test('a fresh turn streams JSON, trusts the run, and names the grid model',
        () {
      // A wrong flag fails exactly like a model that wouldn't answer, so the
      // argv is pinned here rather than trusted by eye.
      expect(piExecArgs(model: 'qwen3'), [
        '--mode',
        'json',
        '--approve',
        '--model',
        'grid/qwen3',
      ]);
    });

    test('resuming adds --session and takes no other subcommand — unlike Codex',
        () {
      expect(piExecArgs(model: 'qwen3', resumeSessionId: 'sess-1'), [
        '--mode',
        'json',
        '--approve',
        '--model',
        'grid/qwen3',
        '--session',
        'sess-1',
      ]);
    });
  });

  group('parsePiEvent — the pi --mode json stream', () {
    test('the first session line carries the id to resume with later', () {
      final event = parsePiEvent(
        {'type': 'session', 'version': 3, 'id': 'abc-123', 'cwd': '/x'},
        PiTurnState(),
      );
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
      final event = parsePiEvent({
        'type': 'message_end',
        'message': {
          'role': 'assistant',
          'stopReason': 'stop',
          'content': [
            {'type': 'text', 'text': 'The answer.'},
          ],
        },
      }, state);
      expect((event as PiMessageEvent).text, 'The answer.');
    });

    test('an assistant message that stopped on an error is a turn failure, with '
        'its own reason', () {
      final event = parsePiEvent({
        'type': 'message_end',
        'message': {
          'role': 'assistant',
          'stopReason': 'error',
          'errorMessage': 'HTTP 503: no providers',
        },
      }, PiTurnState());
      expect(event, isA<PiTurnFailed>());
      expect((event as PiTurnFailed).message, 'HTTP 503: no providers');
    });

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
      expect((ended as PiActivityEvent).activity.status,
          AgentActivityStatus.failed);
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

    test("pi's todowrite tool carries the to-do list as a plan", () {
      final event = parsePiEvent({
        'type': 'tool_execution_start',
        'toolCallId': 'p1',
        'toolName': 'todowrite',
        'args': {
          'todos': [
            {'content': 'Read the files', 'status': 'completed'},
            {'content': 'Write the fix', 'status': 'in_progress'},
            {'content': 'Run the tests', 'status': 'pending'},
          ],
        },
      }, PiTurnState());
      final plan = (event as PiPlanEvent).entries;
      expect(plan.map((e) => e.content), [
        'Read the files',
        'Write the fix',
        'Run the tests',
      ]);
      expect(plan[0].status, AgentPlanStatus.done);
      expect(plan[1].status, AgentPlanStatus.active);
      expect(plan[2].status, AgentPlanStatus.pending);
    });

    test('agent_end — not the per-round turn_end — is how the exchange finishes',
        () {
      expect(
        parsePiEvent({'type': 'turn_end', 'message': {}}, PiTurnState()),
        isNull,
      );
      expect(
        parsePiEvent({'type': 'agent_end', 'messages': <dynamic>[]},
            PiTurnState()),
        isA<PiTurnCompleted>(),
      );
    });
  });
}
