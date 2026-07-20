import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/codex_chat_sender.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_app/infrastructure/cli/agent_version_service.dart';
import 'package:grid_app/infrastructure/cli/codex_exec_service.dart';

void main() {
  group('parseCodexEvent — the codex exec --json thread stream', () {
    test('the opening thread.started carries the id to resume with later', () {
      final event = parseCodexEvent(
        {'type': 'thread.started', 'thread_id': 'abc-123'},
        {},
      );
      expect(event, isA<CodexThreadStarted>());
      expect((event as CodexThreadStarted).threadId, 'abc-123');
    });

    test('an agent message becomes the assembled answer so far', () {
      final messages = <String, String>{};
      final event = parseCodexEvent({
        'type': 'item.completed',
        'item': {'id': 'i0', 'type': 'agent_message', 'text': 'Hello there'},
      }, messages);
      expect(event, isA<CodexMessageEvent>());
      expect((event as CodexMessageEvent).text, 'Hello there');
    });

    test('a second message joins the first — a turn can hold several', () {
      final messages = <String, String>{};
      parseCodexEvent({
        'type': 'item.completed',
        'item': {'id': 'i0', 'type': 'agent_message', 'text': 'First'},
      }, messages);
      final event = parseCodexEvent({
        'type': 'item.completed',
        'item': {'id': 'i1', 'type': 'agent_message', 'text': 'Second'},
      }, messages);
      expect((event as CodexMessageEvent).text, 'First\n\nSecond');
    });

    test('a command step maps to a command activity with its live status', () {
      final started = parseCodexEvent({
        'type': 'item.started',
        'item': {
          'id': 'c1',
          'type': 'command_execution',
          'command': 'ls -la',
          'status': 'in_progress',
        },
      }, {});
      final activity = (started as CodexActivityEvent).activity;
      expect(activity.kind, AgentActivityKind.command);
      expect(activity.label, 'ls -la');
      expect(activity.status, AgentActivityStatus.running);

      final done = parseCodexEvent({
        'type': 'item.completed',
        'item': {
          'id': 'c1',
          'type': 'command_execution',
          'command': 'ls -la',
          'status': 'completed',
        },
      }, {});
      // Same id — the sender upserts it, so the running row turns into a done one.
      expect((done as CodexActivityEvent).activity.id, 'c1');
      expect(done.activity.status, AgentActivityStatus.done);
    });

    test('a web search maps to a web activity labelled by its query', () {
      final event = parseCodexEvent({
        'type': 'item.started',
        'item': {'id': 'w1', 'type': 'web_search', 'query': 'grid p2p ai'},
      }, {});
      final activity = (event as CodexActivityEvent).activity;
      expect(activity.kind, AgentActivityKind.web);
      expect(activity.label, 'grid p2p ai');
    });

    test('a todo list becomes the plan, done vs pending, blanks dropped', () {
      final event = parseCodexEvent({
        'type': 'item.completed',
        'item': {
          'id': 't1',
          'type': 'todo_list',
          'items': [
            {'text': 'Read the files', 'completed': true},
            {'text': 'Write the answer', 'completed': false},
            {'text': '   ', 'completed': false},
          ],
        },
      }, {});
      final entries = (event as CodexPlanEvent).entries;
      expect(entries.length, 2);
      expect(entries[0].status, AgentPlanStatus.done);
      expect(entries[1].status, AgentPlanStatus.pending);
    });

    test('turn.failed is the fatal signal, carrying codex own reason', () {
      final event = parseCodexEvent({
        'type': 'turn.failed',
        'error': {'message': 'stream disconnected'},
      }, {});
      expect(event, isA<CodexTurnFailed>());
      expect((event as CodexTurnFailed).message, 'stream disconnected');
    });

    test('a bare error is a transient reconnect notice, not a failure', () {
      final event = parseCodexEvent(
        {'type': 'error', 'message': 'Reconnecting... 1/5'},
        {},
      );
      expect(event, isNull);
    });

    test('turn lifecycle chatter and unknown items surface nothing', () {
      expect(parseCodexEvent({'type': 'turn.started'}, {}), isNull);
      expect(parseCodexEvent({'type': 'turn.completed'}, {}), isNull);
      expect(
        parseCodexEvent({
          'type': 'item.completed',
          'item': {'id': 'r1', 'type': 'reasoning', 'text': 'thinking'},
        }, {}),
        isNull,
      );
    });
  });

  group('parseSemver — codex banner', () {
    test('pulls the version out of "codex-cli 0.141.0"', () {
      expect(parseSemver('codex-cli 0.141.0'), '0.141.0');
    });

    test('a banner without a version reads as unknown', () {
      expect(parseSemver('command not found'), isNull);
      expect(parseSemver(''), isNull);
    });
  });

  group('friendlyCodexError — a next step, not a stack trace', () {
    test('the responses wall is named in the app own terms', () {
      final message = friendlyCodexError(
        'stream disconnected before completion: error sending request for url '
        '(http://host/v1/responses)',
      );
      expect(message.toLowerCase(), contains("can't run codex yet"));
    });

    test('any other failure keeps codex own last line', () {
      expect(
        friendlyCodexError('boom\nauthentication failed'),
        contains('authentication failed'),
      );
    });

    test('a silent failure still says what to do', () {
      expect(friendlyCodexError('   '), contains('try again'));
    });
  });
}
