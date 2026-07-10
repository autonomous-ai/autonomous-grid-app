import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/codex_event.dart';

void main() {
  group('parseCodexEvent', () {
    test('thread.started carries the thread id', () {
      final event = parseCodexEvent(
        '{"type":"thread.started","thread_id":"abc-123"}',
      );
      expect(event, isA<CodexThreadStarted>());
      expect((event as CodexThreadStarted).threadId, 'abc-123');
    });

    test('a completed agent_message becomes the answer text', () {
      final event = parseCodexEvent(
        '{"type":"item.completed","item":'
        '{"id":"item_1","type":"agent_message","text":"hello world"}}',
      );
      expect(event, isA<CodexAgentMessage>());
      expect((event as CodexAgentMessage).text, 'hello world');
    });

    test('a completed error item is a non-fatal item error', () {
      final event = parseCodexEvent(
        '{"type":"item.completed","item":'
        '{"id":"item_0","type":"error","message":"metadata fallback"}}',
      );
      expect(event, isA<CodexItemError>());
      expect((event as CodexItemError).message, 'metadata fallback');
    });

    test('turn.failed pulls the nested error message', () {
      final event = parseCodexEvent(
        '{"type":"turn.failed","error":{"message":"boom"}}',
      );
      expect(event, isA<CodexTurnFailed>());
      expect((event as CodexTurnFailed).message, 'boom');
    });

    test('a top-level error keeps its message', () {
      final event = parseCodexEvent(
        '{"type":"error","message":"Reconnecting... 1/5"}',
      );
      expect(event, isA<CodexStreamError>());
      expect((event as CodexStreamError).message, 'Reconnecting... 1/5');
    });

    test('turn.started / turn.completed map to their events', () {
      expect(
        parseCodexEvent('{"type":"turn.started"}'),
        isA<CodexTurnStarted>(),
      );
      expect(
        parseCodexEvent('{"type":"turn.completed"}'),
        isA<CodexTurnCompleted>(),
      );
    });

    test('in-progress items are ignored, not surfaced as answers', () {
      final event = parseCodexEvent(
        '{"type":"item.updated","item":'
        '{"type":"agent_message","text":"partial"}}',
      );
      expect(event, isA<CodexUnknownEvent>());
    });

    test('blank and non-JSON lines return null', () {
      expect(parseCodexEvent(''), isNull);
      expect(parseCodexEvent('   '), isNull);
      expect(parseCodexEvent('Reading additional input from stdin...'), isNull);
    });

    test('an unknown event type is a recognised-but-ignored envelope', () {
      expect(
        parseCodexEvent('{"type":"token_count"}'),
        isA<CodexUnknownEvent>(),
      );
    });

    test('reasoning items are ignored (too verbose to surface)', () {
      final event = parseCodexEvent(
        '{"type":"item.completed","item":'
        '{"id":"item_1","type":"reasoning","text":"long thoughts"}}',
      );
      expect(event, isA<CodexUnknownEvent>());
    });
  });

  group('parseCodexEvent activity', () {
    test('a started command becomes a running step, label unwrapped', () {
      final event = parseCodexEvent(
        '{"type":"item.started","item":{"id":"item_2",'
        '"type":"command_execution","command":"/bin/sh -lc \'ls /tmp/sb\'",'
        '"aggregated_output":"","exit_code":null,"status":"in_progress"}}',
      );
      expect(event, isA<CodexActivityUpdate>());
      final step = (event as CodexActivityUpdate).activity;
      expect(step.id, 'item_2');
      expect(step.kind, CodexActivityKind.command);
      expect(step.label, 'ls /tmp/sb');
      expect(step.status, CodexActivityStatus.running);
    });

    test('a completed command with exit 0 is done', () {
      final event = parseCodexEvent(
        '{"type":"item.completed","item":{"id":"item_2",'
        '"type":"command_execution","command":"/bin/sh -lc \'ls\'",'
        '"aggregated_output":"a\\n","exit_code":0,"status":"completed"}}',
      );
      expect(
        (event as CodexActivityUpdate).activity.status,
        CodexActivityStatus.done,
      );
    });

    test('a completed command with a non-zero exit is failed', () {
      final event = parseCodexEvent(
        '{"type":"item.completed","item":{"id":"item_2",'
        '"type":"command_execution","command":"/bin/sh -lc \'nope\'",'
        '"aggregated_output":"","exit_code":127,"status":"completed"}}',
      );
      expect(
        (event as CodexActivityUpdate).activity.status,
        CodexActivityStatus.failed,
      );
    });

    test('a tool call carrying an error is failed, labelled by tool', () {
      final event = parseCodexEvent(
        '{"type":"item.completed","item":{"id":"item_4",'
        '"type":"mcp_tool_call","server":"s","tool":"read_mcp_resource",'
        '"arguments":{},"result":null,"error":{"message":"boom"},'
        '"status":"failed"}}',
      );
      final step = (event as CodexActivityUpdate).activity;
      expect(step.kind, CodexActivityKind.tool);
      expect(step.label, 'read_mcp_resource');
      expect(step.status, CodexActivityStatus.failed);
    });
  });
}
