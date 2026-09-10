import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/adapters/claude_chat_sender.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_app/infrastructure/cli/agent_question.dart';
import 'package:grid_app/infrastructure/cli/claude_content.dart';
import 'package:grid_app/infrastructure/cli/claude_exec_event.dart';
import 'package:grid_app/infrastructure/cli/claude_exec_service.dart';
import 'package:grid_app/infrastructure/cli/claude_permission.dart';
import 'package:grid_app/infrastructure/cli/claude_stream_parser.dart';
import 'package:grid_app/infrastructure/cli/claude_tools.dart';

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
Map<String, dynamic> _assistant(
  Map<String, dynamic> block, {
  Map<String, dynamic>? usage,
}) => {
  'type': 'assistant',
  'message': {
    'content': [block],
    'usage': ?usage,
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

/// A tool's answer, as the CLI hands it back.
Map<String, dynamic> _answered(String id, String text) => {
  'type': 'user',
  'message': {
    'content': [
      {'type': 'tool_result', 'tool_use_id': id, 'content': text},
    ],
  },
};

/// One of Claude Code 2.1's task-list calls.
Map<String, dynamic> _task(
  String id,
  String name,
  Map<String, dynamic> input,
) => _assistant({'type': 'tool_use', 'id': id, 'name': name, 'input': input});

/// The plan an event carries, as (wording, status) pairs.
List<(String, AgentPlanStatus)> _planOf(ClaudeExecEvent event) => [
  for (final entry in (event as ClaudePlanEvent).entries)
    (entry.content, entry.status),
];

/// A backgrounded `Agent` call, as the model makes it.
Map<String, dynamic> _agentCall(String id) => {
  'type': 'tool_use',
  'id': id,
  'name': 'Agent',
  'input': {'prompt': 'probe', 'run_in_background': true},
};

/// The CLI's whole list of what is running in the background.
Map<String, dynamic> _backgroundTasks(List<(String, String)> tasks) => {
  'type': 'system',
  'subtype': 'background_tasks_changed',
  'tasks': [
    for (final (id, description) in tasks)
      {
        'task_id': id,
        'task_type': 'local_workflow',
        'description': description,
      },
  ],
};

Map<String, dynamic> _taskStarted(String task, String call) => {
  'type': 'system',
  'subtype': 'task_started',
  'task_id': task,
  'tool_use_id': call,
};

Map<String, dynamic> _result(String text) => {
  'type': 'result',
  'subtype': 'success',
  'is_error': false,
  'result': text,
};

/// A `ScheduleWakeup` call — a booking, or `stop: true` to un-book.
Map<String, dynamic> _wakeupCall(
  String id, {
  int delay = 60,
  bool stop = false,
}) => {
  'type': 'tool_use',
  'id': id,
  'name': 'ScheduleWakeup',
  'input': stop
      ? {'stop': true}
      : {'delaySeconds': delay, 'prompt': 'tick', 'reason': 'probe'},
};

Map<String, dynamic> _schedulerCall(String id, String name) => {
  'type': 'tool_use',
  'id': id,
  'name': name,
  'input': {'cron': '* * * * *', 'prompt': 'tick'},
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

    test("a turn on the user's own subscription names no model at all, so the "
        'CLI answers on whatever their own claude is set to — an empty string '
        'here would be a model named nothing', () {
      final args = claudeExecArgs(model: null);
      expect(args, isNot(contains('--model')));
      expect(args, isNot(contains('')));
      // Everything else about the turn is unchanged: it is the same lane, on a
      // different account.
      expect(args.first, '-p');
      expect(args, containsAllInOrder(['--output-format', 'stream-json']));
    });

    test('a later turn resumes the session instead of replaying the chat', () {
      final args = claudeExecArgs(model: 'm', resumeSessionId: 'sess-1');
      expect(args, containsAllInOrder(['--resume', 'sess-1']));
    });

    test('only claude-api is switched off, as a --settings override — the '
        'all-or-nothing env var took /loop with it, so a loop typed into the '
        'Messages lane ran once as prose', () {
      final args = claudeExecArgs(model: 'm', withoutServerWebTools: true);
      final flag = args.indexOf('--settings');
      expect(flag, greaterThan(0));
      expect(jsonDecode(args[flag + 1]), {
        'skillOverrides': {'claude-api': 'off'},
      });
      expect(kClaudeSkillOverrides.keys, ['claude-api']);
      // The override is one value, so the variadic --disallowedTools after it
      // still reads exactly the web tools and nothing of the settings.
      expect(args, isNot(contains('CLAUDE_CODE_DISABLE_BUNDLED_SKILLS')));
    });

    test('a turn with nothing to take away passes no --disallowedTools at '
        'all — a bare flag is an empty list the CLI has to make sense of', () {
      final args = claudeExecArgs(model: 'm');
      expect(args, isNot(contains('--disallowedTools')));
      for (final tool in kClaudeSessionSchedulerTools) {
        expect(args, isNot(contains(tool)));
      }
    });

    test('the wake-up timer goes with the cron tools: it is the one an agent '
        'reaches for when asked for a loop, and it dies with the turn', () {
      expect(kClaudeSessionSchedulerTools, contains('ScheduleWakeup'));
    });

    test('a relay turn takes away the web tools on one --disallowedTools — a '
        'second would be the CLI\'s to reconcile', () {
      final args = claudeExecArgs(model: 'm', withoutServerWebTools: true);
      expect(args.where((a) => a == '--disallowedTools'), hasLength(1));
      final flag = args.indexOf('--disallowedTools');
      expect(
        args.sublist(flag + 1, flag + 1 + kClaudeServerWebTools.length),
        kClaudeServerWebTools,
      );
    });

    test('a persistent monitor is refused with its reason, not put to the '
        'user: a yes could not make it outlive the turn it was asked in', () {
      final refusal = claudeToolRefusal('Monitor', {
        'persistent': true,
        'command': 'git fetch origin',
      });

      expect(refusal, kClaudePersistentMonitorRefusal);
      // The way out it names has to be a place that exists (§5).
      expect(refusal, contains('Scheduled'));
    });

    test('a monitor that finishes inside the turn is left alone — waiting for '
        'a server to come up is what the tool is for', () {
      expect(claudeToolRefusal('Monitor', {'command': 'curl localhost'}), null);
      expect(claudeToolRefusal('Bash', {'persistent': true}), null);
    });

    test('a refusal reaches the model as the reason, so it can take the route '
        'that works instead of narrating a dead end', () {
      final response =
          claudePermissionResponse(
                requestId: 'r-1',
                optionId: kRefuseOption,
                denyMessage: kClaudePersistentMonitorRefusal,
              )['response']
              as Map<String, Object?>;
      final inner = response['response'] as Map<String, Object?>;

      expect(inner['behavior'], 'deny');
      expect(inner['message'], kClaudePersistentMonitorRefusal);
    });

    test('a plain no still says a person said it, so the model does not read '
        'every refusal as a rule of the app', () {
      final response =
          claudePermissionResponse(requestId: 'r-2', optionId: null)['response']
              as Map<String, Object?>;
      final inner = response['response'] as Map<String, Object?>;

      expect(inner['message'], 'The person asked said no.');
    });

    test('the tool and input of a request are read off the line the CLI sent, '
        'because what is refused depends on both', () {
      final line = {
        'type': 'control_request',
        'request_id': 'r-3',
        'request': {
          'subtype': 'can_use_tool',
          'tool_name': 'Monitor',
          'input': {'persistent': true, 'timeout_ms': 3600000},
        },
      };

      expect(claudePermissionTool(line), 'Monitor');
      expect(claudePermissionInput(line)['persistent'], true);
      expect(claudePermissionTool(const {'type': 'control_response'}), '');
    });

    test('a finished turn does not leave its process behind — one that stayed '
        'ran two hours past its own answer', () {
      expect(kClaudeExitGrace, const Duration(seconds: 5));
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

    test("Claude Code 2.1's task tools are the plan under -p — made, then "
        'ticked off, and sent whole each time it changes', () {
      final parser = ClaudeStreamParser();
      // The call alone is no row, and the task has no number yet.
      expect(
        _read(
          parser,
          _task('c1', 'TaskCreate', {
            'subject': 'Read the code',
            'description': 'All of lib/',
            'activeForm': 'Reading the code',
          }),
        ),
        isEmpty,
      );
      expect(
        _planOf(
          _one(
            parser,
            _answered('c1', 'Task #1 created successfully: Read the code'),
          ),
        ),
        [('Read the code', AgentPlanStatus.pending)],
      );
      _read(parser, _task('c2', 'TaskCreate', {'subject': 'Fix the test'}));
      _read(
        parser,
        _answered('c2', 'Task #2 created successfully: Fix the test'),
      );
      expect(
        _planOf(
          _one(
            parser,
            _task('u1', 'TaskUpdate', {'taskId': '1', 'status': 'completed'}),
          ),
        ),
        [
          ('Read the code', AgentPlanStatus.done),
          ('Fix the test', AgentPlanStatus.pending),
        ],
      );
      // The update's own answer settles nothing: it was never a row.
      expect(_read(parser, _answered('u1', 'Updated task #1 status')), isEmpty);
    });

    test('a deleted task leaves the plan, and an update to a task this turn '
        'never saw made is passed over rather than drawn with no words', () {
      final parser = ClaudeStreamParser();
      _read(parser, _task('c1', 'TaskCreate', {'subject': 'Draft'}));
      _read(parser, _answered('c1', 'Task #4 created successfully: Draft'));
      expect(
        _read(
          parser,
          _task('u9', 'TaskUpdate', {'taskId': '2', 'status': 'completed'}),
        ),
        isEmpty,
      );
      final gone = _one(
        parser,
        _task('u1', 'TaskUpdate', {'taskId': '4', 'status': 'deleted'}),
      );
      expect((gone as ClaudePlanEvent).entries, isEmpty);
    });

    test("a sub-agent's task list is its own — it neither replaces the plan "
        'nor adds rows — and reading the list is not a step either', () {
      final parser = ClaudeStreamParser();
      expect(
        _read(parser, {
          'type': 'assistant',
          'parent_tool_use_id': 'a1',
          'message': {
            'content': [
              {
                'type': 'tool_use',
                'id': 'c1',
                'name': 'TaskCreate',
                'input': {'subject': 'Its own'},
              },
            ],
          },
        }),
        isEmpty,
      );
      expect(_read(parser, _task('l1', 'TaskList', const {})), isEmpty);
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

    test('a result that leaves background work running is not the end: the '
        'answer stands, a waiting row goes up, and the turn stays open', () {
      final parser = ClaudeStreamParser();
      _read(parser, _assistant(_agentCall('t-1')));
      _read(parser, _backgroundTasks([('w1', 'Deep research')]));
      _read(parser, _taskStarted('w1', 't-1'));
      _read(parser, _toolResult('t-1'));

      final events = _read(parser, _result('started'));

      expect((events[0] as ClaudeMessageEvent).text, 'started');
      final waiting = (events[1] as ClaudeActivityEvent).activity;
      expect(waiting.id, 'background-wait-1');
      expect(waiting.status, AgentActivityStatus.running);
      expect(waiting.request, 'Deep research');
      expect((events[2] as ClaudeTurnWaiting).pending, ['Deep research']);
      expect(events.whereType<ClaudeTurnCompleted>(), isEmpty);
    });

    test('the second turn appends to the first answer instead of replacing '
        'it, and its result is the one that ends the turn', () {
      final parser = ClaudeStreamParser();
      _read(parser, _backgroundTasks([('w1', 'Deep research')]));
      _read(parser, _result('started'));

      _read(parser, _backgroundTasks(const []));
      _read(parser, {'type': 'system', 'subtype': 'init', 'session_id': 's'});
      final streamed = _read(parser, _delta('The workflow found'));
      expect(
        (streamed.single as ClaudeMessageEvent).text,
        'started\n\nThe workflow found',
      );
      final events = _read(parser, _result('The workflow found X.'));

      expect(
        (events.first as ClaudeMessageEvent).text,
        'started\n\nThe workflow found X.',
      );
      expect(events.last, isA<ClaudeTurnCompleted>());
    });

    test('a task that finishes before the answer does still keeps the turn '
        'open — the CLI queues its notification and starts a turn to report '
        'it, and killing the process five seconds after the result cut that '
        'report off mid-sentence ("pong" never arrived)', () {
      final parser = ClaudeStreamParser();
      _read(parser, _assistant(_agentCall('t-1')));
      _read(parser, _backgroundTasks([('w1', 'Reply pong')]));
      _read(parser, _taskStarted('w1', 't-1'));
      _read(parser, _toolResult('t-1'));
      // The sub-agent is done before the model has finished saying "launched".
      _read(parser, _backgroundTasks(const []));
      _read(parser, {
        'type': 'system',
        'subtype': 'task_notification',
        'task_id': 'w1',
        'tool_use_id': 't-1',
        'status': 'completed',
        'summary': 'pong',
      });

      final events = _read(parser, _result('launched'));
      final wait = (events[1] as ClaudeActivityEvent).activity;
      expect(wait.label, 'Waiting for the report on background work');
      final waiting = events.last as ClaudeTurnWaiting;
      expect(waiting.pending, ['1 finished task to report']);
      expect(waiting.reportsOnly, isTrue);

      // The reporting turn starts, reads the queue, and its result is the end.
      final started = _read(parser, {
        'type': 'system',
        'subtype': 'init',
        'session_id': 's',
      });
      expect(
        started.whereType<ClaudeActivityEvent>().single.activity.status,
        AgentActivityStatus.done,
      );
      expect(
        _read(parser, _result('It said pong.')).last,
        isA<ClaudeTurnCompleted>(),
      );
    });

    test('a notification the model read inside the turn — it went on talking '
        'after it — is owed nothing, so the result is the end: measured, the '
        'CLI folds it into that call and never answers it separately', () {
      final parser = ClaudeStreamParser();
      _read(parser, _assistant(_agentCall('t-1')));
      _read(parser, _backgroundTasks([('w1', 'Reply pong')]));
      _read(parser, _taskStarted('w1', 't-1'));
      _read(parser, _backgroundTasks(const []));
      _read(parser, {
        'type': 'system',
        'subtype': 'task_notification',
        'task_id': 'w1',
        'status': 'completed',
        'summary': 'pong',
      });
      _read(parser, _assistant({'type': 'text', 'text': 'It said pong.'}));

      expect(
        _read(parser, _result('It said pong.')).last,
        isA<ClaudeTurnCompleted>(),
      );
    });

    test('giving up a wait settles its row and ends the turn — and is a no-op '
        'on a turn that is not waiting', () {
      final parser = ClaudeStreamParser();
      expect(parser.giveUpWaiting(), isEmpty);
      _read(parser, _backgroundTasks([('w1', 'probe')]));
      _read(parser, _backgroundTasks(const []));
      _read(parser, {
        'type': 'system',
        'subtype': 'task_notification',
        'task_id': 'w1',
        'status': 'completed',
      });
      _read(parser, _result('launched'));

      final events = parser.giveUpWaiting();

      expect(
        (events.first as ClaudeActivityEvent).activity.status,
        AgentActivityStatus.done,
      );
      expect(events.last, isA<ClaudeTurnCompleted>());
      expect(parser.giveUpWaiting(), isEmpty);
    });

    test("a workflow's progress lands on the call that started it, in the "
        'TUI\'s own count — its agents never report on stdout themselves', () {
      final parser = ClaudeStreamParser();
      _read(parser, _assistant(_agentCall('t-1')));
      _read(parser, _backgroundTasks([('w1', 'three numbers')]));
      _read(parser, _taskStarted('w1', 't-1'));

      final events = _read(parser, {
        'type': 'system',
        'subtype': 'task_progress',
        'task_id': 'w1',
        'tool_use_id': 't-1',
        'usage': {'total_tokens': 16167, 'tool_uses': 0, 'duration_ms': 3297},
        'workflow_progress': [
          {'type': 'workflow_phase', 'index': 1, 'title': 'Run'},
          {
            'type': 'workflow_agent',
            'label': 'one',
            'phaseTitle': 'Run',
            'state': 'done',
          },
          {
            'type': 'workflow_agent',
            'label': 'two',
            'phaseTitle': 'Run',
            'state': 'start',
          },
          {
            'type': 'workflow_agent',
            'label': 'three',
            'phaseTitle': 'Run',
            'state': 'start',
          },
        ],
      });

      final row = (events.single as ClaudeActivityEvent).activity;
      expect(row.id, 't-1');
      expect(row.status, AgentActivityStatus.running);
      expect(row.result, '1/3 agents done · Run: three');
      // Progress for a task nobody waited on shows nothing.
      expect(
        _read(parser, {
          'type': 'system',
          'subtype': 'task_progress',
          'task_id': 'unknown',
        }),
        isEmpty,
      );
    });

    test('a plain background task reports its last tool, its calls and its '
        'time — and nothing when the event carries none of them', () {
      expect(
        claudeTaskProgress({
          'last_tool_name': 'Grep',
          'usage': {'tool_uses': 2, 'duration_ms': 3297},
        }),
        'Grep · 2 tool calls · 3s',
      );
      expect(
        claudeTaskProgress({
          'usage': {'duration_ms': 20},
        }),
        isNull,
      );
    });

    test('the background list emptying settles the waiting row, and the '
        'task\'s notification settles the call that started it with the real '
        'outcome — not the "launched in background" placeholder', () {
      final parser = ClaudeStreamParser();
      _read(parser, _assistant(_agentCall('t-1')));
      _read(parser, _backgroundTasks([('w1', 'probe')]));
      _read(parser, _taskStarted('w1', 't-1'));
      _read(parser, _toolResult('t-1'));
      _read(parser, _result('started'));

      final cleared = _read(parser, _backgroundTasks(const []));
      final settled = _read(parser, {
        'type': 'system',
        'subtype': 'task_notification',
        'task_id': 'w1',
        'tool_use_id': 't-1',
        'status': 'completed',
        'summary': 'Dynamic workflow "probe" completed',
      });

      final wait = (cleared.single as ClaudeActivityEvent).activity;
      expect(wait.id, 'background-wait-1');
      expect(wait.status, AgentActivityStatus.done);
      final call = (settled.single as ClaudeActivityEvent).activity;
      expect(call.id, 't-1');
      expect(call.status, AgentActivityStatus.done);
      expect(call.result, contains('completed'));
    });

    test('a failed background task marks its call failed, and a notification '
        'for a task nobody waited on shows nothing', () {
      final parser = ClaudeStreamParser();
      _read(parser, _assistant(_agentCall('t-1')));
      _read(parser, _backgroundTasks([('w1', 'probe')]));
      _read(parser, _taskStarted('w1', 't-1'));

      final failed = _read(parser, {
        'type': 'system',
        'subtype': 'task_notification',
        'task_id': 'w1',
        'status': 'failed',
        'summary': 'boom',
      });
      expect(
        (failed.single as ClaudeActivityEvent).activity.status,
        AgentActivityStatus.failed,
      );
      expect(
        _read(parser, {
          'type': 'system',
          'subtype': 'task_notification',
          'task_id': 'unknown',
          'status': 'completed',
        }),
        isEmpty,
      );
    });

    test('a sub-agent\'s own shell command is reported on the same line and '
        'is nobody\'s to wait for', () {
      final parser = ClaudeStreamParser();
      _read(parser, _assistant(_agentCall('t-1')));
      // No background list names it: it is a helper's foreground step.
      _read(parser, _taskStarted('b1', 't-1'));

      expect(_read(parser, _result('done')).last, isA<ClaudeTurnCompleted>());
    });

    test(
      'a booked wake-up keeps the turn open — Claude Code\'s own /loop, '
      'which used to die with the process five seconds after "scheduled"',
      () {
        final parser = ClaudeStreamParser();
        _read(parser, _assistant(_wakeupCall('w-1', delay: 60)));
        _read(parser, _toolResult('w-1'));

        final events = _read(parser, _result('scheduled'));

        expect(events.whereType<ClaudeTurnCompleted>(), isEmpty);
        final wait = (events[1] as ClaudeActivityEvent).activity;
        expect(wait.label, 'Waiting for the next tick');
        expect(wait.request, 'next tick in 60s — probe');
        expect((events[2] as ClaudeTurnWaiting).pending, [
          'next tick in 60s — probe',
        ]);
      },
    );

    test('the tick is the next init: it settles the wait, its words follow '
        'the last answer, and a tick that books no wake-up ends the turn', () {
      final parser = ClaudeStreamParser();
      _read(parser, _assistant(_wakeupCall('w-1', delay: 60)));
      _read(parser, _toolResult('w-1'));
      _read(parser, _result('scheduled'));

      final tick = _read(parser, {
        'type': 'system',
        'subtype': 'init',
        'session_id': 's',
      });
      expect(
        tick.whereType<ClaudeActivityEvent>().single.activity.status,
        AgentActivityStatus.done,
      );
      final events = _read(parser, _result('all quiet'));

      expect(
        (events.first as ClaudeMessageEvent).text,
        'scheduled\n\nall quiet',
      );
      expect(events.last, isA<ClaudeTurnCompleted>());
    });

    test('a second wake-up in the same turn is a second wait, with a row of '
        'its own after the tick\'s words', () {
      final parser = ClaudeStreamParser();
      _read(parser, _assistant(_wakeupCall('w-1', delay: 60)));
      _read(parser, _toolResult('w-1'));
      _read(parser, _result('scheduled'));
      _read(parser, {'type': 'system', 'subtype': 'init', 'session_id': 's'});
      _read(parser, _assistant(_wakeupCall('w-2', delay: 120)));
      _read(parser, _toolResult('w-2'));

      final events = _read(parser, _result('tick one'));

      final wait = (events[1] as ClaudeActivityEvent).activity;
      expect(wait.id, 'background-wait-2');
      expect(wait.request, 'next tick in 120s — probe');
      expect(events.last, isA<ClaudeTurnWaiting>());
    });

    test('stop: true un-books the wake-up, and a wake-up the CLI refused '
        'never booked one — either way the result ends the turn', () {
      final stopped = ClaudeStreamParser();
      _read(stopped, _assistant(_wakeupCall('w-1', delay: 60)));
      _read(stopped, _toolResult('w-1'));
      _read(stopped, _assistant(_wakeupCall('w-2', stop: true)));
      _read(stopped, _toolResult('w-2'));
      expect(_read(stopped, _result('done')).last, isA<ClaudeTurnCompleted>());

      final refused = ClaudeStreamParser();
      _read(refused, _assistant(_wakeupCall('w-1', delay: 60)));
      _read(refused, _toolResult('w-1', failed: true));
      expect(_read(refused, _result('done')).last, isA<ClaudeTurnCompleted>());
    });

    test('a cron job keeps the turn open until it is deleted — it fires only '
        'while the process lives', () {
      final parser = ClaudeStreamParser();
      _read(parser, _assistant(_schedulerCall('c-1', 'CronCreate')));
      _read(parser, _toolResult('c-1'));
      final open = _read(parser, _result('created'));
      expect((open.last as ClaudeTurnWaiting).pending, ['1 scheduled job']);
      // The row says what it waits for. A cron is a tick like a wake-up is —
      // it used to fall through to the task count and read "Waiting for 0
      // background tasks to finish".
      final wait = open.whereType<ClaudeActivityEvent>().single.activity;
      expect(wait.label, 'Waiting for the next tick');
      expect(wait.request, '1 scheduled job');

      _read(parser, {'type': 'system', 'subtype': 'init', 'session_id': 's'});
      _read(parser, _assistant(_schedulerCall('c-2', 'CronDelete')));
      _read(parser, _toolResult('c-2'));
      expect(
        _read(parser, _result('deleted')).last,
        isA<ClaudeTurnCompleted>(),
      );
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

  group('a question the CLI answers for us reaches the user anyway', () {
    Map<String, dynamic> ask(Object? questions) => _assistant({
      'type': 'tool_use',
      'id': 'q1',
      'name': 'AskUserQuestion',
      'input': {'questions': questions},
    });

    test('the question leaves the stream as something to answer, not a row to '
        'read — under claude -p the CLI answers it itself, so a tool row is '
        'the one shape the user cannot act on', () {
      final event = _one(
        ClaudeStreamParser(),
        ask([
          {
            'question': 'How often should the review loop run?',
            'header': 'Frequency',
            'options': [
              {
                'label': 'On every change',
                'description': 'Runs on each commit.',
              },
              {'label': 'Daily', 'description': 'One pass a day.'},
            ],
          },
        ]),
      );

      final questions = (event as ClaudeQuestionsEvent).questions;
      expect(questions.single.header, 'Frequency');
      expect(questions.single.options.map((o) => o.label), [
        'On every change',
        'Daily',
      ]);
    });

    test('a call carrying nothing answerable stays an ordinary row, so a '
        'malformed question is visible rather than swallowed', () {
      final event = _one(ClaudeStreamParser(), ask('not a list'));

      expect(event, isA<ClaudeActivityEvent>());
    });

    test('entering plan mode keeps its row but drops the page of instructions '
        'the CLI writes back to the model — it is addressed to the assistant, '
        'and it read as the app ordering the user about', () {
      final parser = ClaudeStreamParser();
      _read(
        parser,
        _assistant({
          'type': 'tool_use',
          'id': 'p1',
          'name': 'EnterPlanMode',
          'input': <String, dynamic>{},
        }),
      );

      final settled = _one(parser, {
        'type': 'user',
        'message': {
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'p1',
              'content': 'Entered plan mode. You should now focus on…',
            },
          ],
        },
      });

      final step = (settled as ClaudeActivityEvent).activity;
      expect(step.result, isNull);
      expect(step.status, AgentActivityStatus.done);
      // Titled in the user's words: this tool acts on nothing, so the label
      // would otherwise be the CLI's own identifier.
      expect(step.label, 'Planning before changing anything');
    });
  });

  group('a tool row says what it was about, not what it was called', () {
    test(
      'a sub-agent row carries the job it was given — the tool is `Agent` in '
      'Claude Code 2.x, and titling only `Task` left every one of them '
      'reading "Agent" with its description dropped',
      () {
        expect(
          claudeTool('Agent').label(const {
            'description': 'Review the diff',
            'subagent_type': 'code-reviewer',
          }),
          'Agent · Review the diff',
        );
        // The older name still answers, since the app pins no CLI version.
        expect(
          claudeTool('Task').label(const {'description': 'Review the diff'}),
          'Task · Review the diff',
        );
      },
    );

    test('a skill row names the skill that ran', () {
      expect(
        claudeTool(
          'Skill',
        ).label(const {'skill': 'grid-web', 'args': 'flutter'}),
        'Skill · grid-web',
      );
    });

    test('a connector row drops the wire identifier for the server and tool '
        'behind it — a row spent entirely on `mcp__…__…` names nothing the '
        'user chose', () {
      expect(
        claudeTool(
          'mcp__gitnexus__impact',
        ).label(const {'target': 'ChatStore'}),
        'gitnexus · impact · ChatStore',
      );
    });

    test('a read of part of a file says which lines — the offset is the '
        'first line as the result numbers it, not the one before', () {
      String read(Map<String, dynamic> input) => claudeTool(
        'Read',
      ).label({'file_path': '/r/conventions.md', ...input});
      expect(
        read({'offset': 490, 'limit': 80}),
        'Read · conventions.md (lines 490–569)',
      );
      expect(read({'offset': 12}), 'Read · conventions.md (from line 12)');
      expect(read({'limit': 200}), 'Read · conventions.md (lines 1–200)');
      expect(read(const {}), 'Read · conventions.md');
    });

    test('a connector row takes its subject from the arguments connectors '
        'here actually send, and never prints a list as one', () {
      expect(
        claudeTool(
          'mcp__gitnexus__detect_changes',
        ).label(const {'repo': 'grid-app', 'scope': 'all'}),
        'gitnexus · detect changes · grid-app',
      );
      expect(
        claudeTool('mcp__grid__grid_guide').label(const {'topic': 'loop'}),
        'grid · grid guide · loop',
      );
      expect(
        claudeTool('mcp__grid__web_search').label(const {
          'query': ['a', 'b'],
        }),
        'grid · web search',
      );
    });

    test('a tool search names the tools it went to load, the way the feed '
        'names them', () {
      expect(
        claudeTool('ToolSearch').label(const {
          'query': 'select:mcp__gitnexus__impact,Monitor',
          'max_results': 2,
        }),
        'ToolSearch · gitnexus impact, Monitor',
      );
      expect(
        claudeTool('ToolSearch').label(const {'query': 'slack send'}),
        'ToolSearch · slack send',
      );
    });

    test('a tool nobody has told the app about still gets a row, titled by '
        'the file it touched', () {
      final tool = claudeTool('SomethingNew');
      expect(tool.label(const {'file_path': '/r/a.md'}), 'SomethingNew · a.md');
      expect(tool.kind, AgentActivityKind.tool);
      expect(tool.editsFiles, isFalse);
    });

    test('only the file tools edit files — which is what makes a permission '
        'an edit, and a write something the chat can open', () {
      expect(
        [
          for (final name in ['Edit', 'Write', 'NotebookEdit', 'Read', 'Bash'])
            claudeTool(name).editsFiles,
        ],
        [true, true, true, false, false],
      );
    });
  });

  group('a file change opens as the change it made, not as its arguments', () {
    test('an edit is the lines it swaps, as a diff with the file named', () {
      expect(
        claudeTool('Edit').request(const {
          'file_path': '/repo/lib/a.dart',
          'old_string': 'one\ntwo\nthree',
          'new_string': 'one\n2\nthree',
        }),
        '--- /repo/lib/a.dart\n'
        '+++ /repo/lib/a.dart\n'
        ' one\n'
        '-two\n'
        '+2\n'
        ' three',
      );
    });

    test('a write is the file it wrote — readable, and copyable', () {
      expect(
        claudeTool('Write').request(const {
          'file_path': '/repo/a.md',
          'content': '# Title\n\nBody\n',
        }),
        '# Title\n\nBody\n',
      );
    });

    test('an edit that changes nothing keeps its arguments, rather than a '
        'diff with no lines in it', () {
      expect(
        claudeTool('Edit').request(const {
          'file_path': 'a',
          'old_string': 'x',
          'new_string': 'x',
        }),
        startsWith('{'),
      );
    });

    test('the row a call opens carries the change', () {
      final events = _read(
        ClaudeStreamParser(),
        _assistant({
          'type': 'tool_use',
          'id': 'e1',
          'name': 'Edit',
          'input': {
            'file_path': '/r/a.dart',
            'old_string': 'a',
            'new_string': 'b',
          },
        }),
      );
      final activity = events.whereType<ClaudeActivityEvent>().single.activity;
      expect(activity.request, '--- /r/a.dart\n+++ /r/a.dart\n-a\n+b');
    });
  });

  group('what a tool sent back reads as what it said, not as the wrapping the '
      'CLI puts round it for the model', () {
    test('an error reads as the error — 264 of them in a month arrived inside '
        '<tool_use_error> tags', () {
      expect(
        claudeToolResult(
          '<tool_use_error>String to replace not found in file.'
          '</tool_use_error>',
        ),
        'String to replace not found in file.',
      );
    });

    test(
      'a reminder the CLI put in front of a file is not part of the file',
      () {
        expect(
          claudeToolResult(
            '<system-reminder>This memory is 3 days old.</system-reminder>\n'
            '1\t# Notes',
          ),
          '1\t# Notes',
        );
      },
    );

    test('one it put after the output goes the same way', () {
      expect(
        claudeToolResult('done\n<system-reminder>note</system-reminder>'),
        'done',
      );
    });

    test('a result that is nothing but a reminder keeps its words — it is how '
        'an empty file is reported', () {
      expect(
        claudeToolResult(
          '<system-reminder>Warning: the file exists but the contents are '
          'empty.</system-reminder>',
        ),
        'Warning: the file exists but the contents are empty.',
      );
    });

    test("a reminder in the middle of a result is the file's own text, and "
        'stays', () {
      const file = 'a\n<system-reminder>quoted</system-reminder>\nb';
      expect(claudeToolResult(file), file);
    });

    test("the CLI's refusal reads as the person's no, with their reason when "
        'they gave one', () {
      const refused =
          "The user doesn't want to proceed with this tool use. The tool use "
          'was rejected (eg. if it was a file edit, the new_string was NOT '
          'written to the file).';
      expect(
        claudeToolResult(
          '$refused STOP what you are doing and wait for the user to tell you '
          'how to proceed.',
        ),
        'You said no to this.',
      );
      expect(
        claudeToolResult(
          '$refused The user provided the following reason for the '
          'rejection: wrong file',
        ),
        'You said no: wrong file',
      );
    });

    test('a tool search answers with the tools it loaded — names, not text '
        'blocks, which left its row with nothing to open', () {
      expect(
        claudeToolResult(const [
          {'type': 'tool_reference', 'tool_name': 'mcp__gitnexus__impact'},
          {'type': 'tool_reference', 'tool_name': 'Monitor'},
          {'type': 'image', 'source': <String, Object>{}},
        ]),
        'mcp__gitnexus__impact\nMonitor',
      );
    });

    test('the tidied answer is what lands on the row the call started', () {
      final parser = ClaudeStreamParser();
      _read(
        parser,
        _assistant({
          'type': 'tool_use',
          'id': 'e1',
          'name': 'Edit',
          'input': {
            'file_path': '/r/a.dart',
            'old_string': 'a',
            'new_string': 'b',
          },
        }),
      );
      final done = _one(parser, {
        'type': 'user',
        'message': {
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'e1',
              'is_error': true,
              'content':
                  '<tool_use_error>File has not been read yet.</tool_use_error>',
            },
          ],
        },
      });
      final activity = (done as ClaudeActivityEvent).activity;
      expect(activity.status, AgentActivityStatus.failed);
      expect(activity.result, 'File has not been read yet.');
    });
  });

  group('answerToQuestions — the reply the pick goes back as', () {
    AgentQuestion q(
      String header,
      List<String> options, {
      bool multi = false,
    }) => AgentQuestion(
      question: '$header?',
      header: header,
      multiSelect: multi,
      options: [
        for (final label in options)
          AgentQuestionOption(label: label, description: ''),
      ],
    );

    test('every answer names its question, since the agent asks up to four at '
        'once and a bare list cannot be matched back to them', () {
      final answer = answerToQuestions(
        [
          q('Frequency', ['Daily']),
          q('Scope', ['New code only']),
        ],
        {
          0: {'Daily'},
          1: {'New code only'},
        },
      );

      expect(answer, 'Frequency: Daily\nScope: New code only');
    });

    test('a multi-pick reads in the order the question listed, not the order '
        'they were tapped', () {
      final answer = answerToQuestions(
        [
          q('Lenses', ['Code', 'UI', 'Tester'], multi: true),
        ],
        {
          0: {'Tester', 'Code'},
        },
      );

      expect(answer, 'Lenses: Code, Tester');
    });

    test('a question left alone is left out — silence on one of four is a '
        'truthful answer, a blank line is not', () {
      final answer = answerToQuestions(
        [
          q('Frequency', ['Daily']),
          q('Scope', ['All']),
        ],
        {
          1: {'All'},
        },
      );

      expect(answer, 'Scope: All');
    });

    test('nothing picked answers nothing at all, which is what stops the card '
        'sending an empty message', () {
      expect(
        answerToQuestions([
          q('Frequency', ['Daily']),
        ], const {}),
        isEmpty,
      );
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

  group('claudeContextTokens — how full the window is, per request', () {
    test('both cache halves count: they occupy the window, they were just '
        'cheaper to send', () {
      // Reading `input_tokens` alone is the trap — on a cache-heavy agentic
      // turn it reports a few thousand while the session really holds 230k.
      expect(
        claudeContextTokens({
          'input_tokens': 4,
          'cache_read_input_tokens': 228000,
          'cache_creation_input_tokens': 2000,
          'output_tokens': 141,
        }),
        230145,
      );
    });

    test('a shape with no figure leaves the last one standing rather than '
        'calling a full session empty', () {
      expect(claudeContextTokens(null), isNull);
      expect(claudeContextTokens('nonsense'), isNull);
      expect(claudeContextTokens(const <String, dynamic>{}), isNull);
      expect(claudeContextTokens({'something_else': 10}), isNull);
    });
  });

  group('the stream reports how full the window is', () {
    test('an assistant message carries its request usage', () {
      final events = _read(
        ClaudeStreamParser(),
        _assistant(
          {'type': 'text', 'text': 'Done'},
          usage: {'input_tokens': 1000, 'cache_read_input_tokens': 199000},
        ),
      );
      final used = events.whereType<ClaudeContextUsed>().single;
      expect(used.tokens, 200000);
    });

    test('a message without usage adds nothing — the figure is only ever '
        'replaced by a real one', () {
      final events = _read(
        ClaudeStreamParser(),
        _assistant({'type': 'text', 'text': 'Done'}),
      );
      expect(events.whereType<ClaudeContextUsed>(), isEmpty);
    });

    test("a tool result is Claude talking to itself and reports nobody's "
        'usage', () {
      final events = _read(ClaudeStreamParser(), _toolResult('t1'));
      expect(events.whereType<ClaudeContextUsed>(), isEmpty);
    });
  });

  group('pictures cost context that nothing on the wire reports', () {
    Map<String, dynamic> read(String data, {String? parent}) => {
      'type': 'user',
      'parent_tool_use_id': ?parent,
      'message': {
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 't1',
            'content': [
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': 'image/jpeg',
                  'data': data,
                },
              },
            ],
          },
        ],
      },
    };

    test('a picture is counted from its own payload, because the reported '
        'figure went *down* over ten of them while the engine counted '
        '196000 tokens more', () {
      expect(claudeMediaTokens(null), 0);
      expect(
        claudeMediaTokens([
          {
            'type': 'image',
            'source': {'type': 'base64', 'data': 'x' * 3200},
          },
        ]),
        100,
      );
    });

    test('a bigger picture costs more, so an estimate tracks what a chat is '
        'actually carrying rather than counting screenshots', () {
      int tokensFor(int chars) => claudeMediaTokens([
        {
          'type': 'image',
          'source': {'type': 'base64', 'data': 'x' * chars},
        },
      ]);
      expect(tokensFor(6400), greaterThan(tokensFor(3200)));
    });

    test('text costs nothing here: the reported usage already counts it, and '
        'counting it twice would summarize a chat that had room', () {
      expect(
        claudeMediaTokens([
          {'type': 'text', 'text': 'a' * 3200},
        ]),
        0,
      );
    });

    test('a shape this build has never seen costs nothing rather than '
        'throwing — the parser stays tolerant', () {
      expect(claudeMediaTokens('nonsense'), 0);
      expect(
        claudeMediaTokens([
          {'type': 'image'},
        ]),
        0,
      );
      expect(
        claudeMediaTokens([
          {
            'type': 'image',
            'source': {'type': 'url', 'url': 'https://example.com/a.png'},
          },
        ]),
        0,
      );
    });

    test('the stream hands the estimate over as its own event, so the sender '
        'can add it to the figure rather than replace it', () {
      final events = _read(ClaudeStreamParser(), read('x' * 3200));
      expect(events.whereType<ClaudeMediaUsed>().single.tokens, 100);
    });

    test("a sub-agent's pictures land in its own conversation, not this "
        "session's — the same rule its usage follows", () {
      final events = _read(
        ClaudeStreamParser(),
        read('x' * 3200, parent: 'sub-1'),
      );
      expect(events.whereType<ClaudeMediaUsed>(), isEmpty);
    });
  });

  group('the permission channel — asking is what the flags buy', () {
    test('a turn carries the two-way stdin and the tool that asks on it', () {
      final args = claudeExecArgs(model: 'm');
      expect(args, containsAllInOrder(['--input-format', 'stream-json']));
      expect(
        args,
        containsAllInOrder([
          '--permission-prompt-tool',
          kClaudePermissionPromptTool,
        ]),
      );
    });

    test('no turn runs with nobody asked first', () {
      // The value matters, not just the constant: `bypassPermissions` is what
      // shipped here until 2026-08-18, and it let Claude write files and run
      // commands anywhere on this machine without a single card.
      expect(kClaudePermissionMode, isNot('bypassPermissions'));
      expect(kClaudePermissionMode, 'default');
    });

    test(
      'a shell call reaches the user as the exact command, not a summary',
      () {
        final request = parseClaudePermission({
          'type': 'control_request',
          'request_id': 'r1',
          'request': {
            'subtype': 'can_use_tool',
            'tool_name': 'Bash',
            'input': {
              'command': 'rm -rf build',
              'description': 'Clear the build',
            },
          },
        });
        expect(request, isNotNull);
        expect(request!.kind, AgentPermissionKind.command);
        expect(request.command, 'rm -rf build');
        expect(request.summary, 'Clear the build');
        expect(request.id, 'r1');
        // A command may be agreed to for the whole chat; a file change may not.
        expect(request.canAllowForChat, isTrue);
      },
    );

    test('a whole-file write shows what the file would become', () {
      final request = parseClaudePermission({
        'type': 'control_request',
        'request_id': 'r2',
        'request': {
          'subtype': 'can_use_tool',
          'tool_name': 'Write',
          'input': {'file_path': '/tmp/a.txt', 'content': 'after'},
        },
      }, readBefore: (path) => path == '/tmp/a.txt' ? 'before' : null);
      expect(request!.kind, AgentPermissionKind.edit);
      expect(request.path, '/tmp/a.txt');
      expect(request.oldText, 'before');
      expect(request.newText, 'after');
      expect(request.canAllowForChat, isFalse);
    });

    test('a partial edit is shown as the file with the swap applied, so the '
        'diff is of the real file and not of the fragment', () {
      final request = parseClaudePermission({
        'type': 'control_request',
        'request_id': 'r3',
        'request': {
          'subtype': 'can_use_tool',
          'tool_name': 'Edit',
          'input': {
            'file_path': '/tmp/a.dart',
            'old_string': 'one',
            'new_string': 'two',
          },
        },
      }, readBefore: (_) => 'one and one');
      expect(request!.oldText, 'one and one');
      expect(request.newText, 'two and one');
    });

    test('every occurrence is swapped when the call says so', () {
      expect(
        claudeEditResult({
          'old_string': 'a',
          'new_string': 'b',
          'replace_all': true,
        }, 'a a'),
        'b b',
      );
    });

    test('a tool the app cannot draw is still put to the user, with its whole '
        'request — refusing it unasked is a no from a chat that promised to '
        'ask', () {
      final request = parseClaudePermission({
        'type': 'control_request',
        'request_id': 'r4',
        'request': {
          'subtype': 'can_use_tool',
          'tool_name': 'mcp__notion__create_page',
          'input': {'title': 'Q3'},
        },
      });
      expect(request!.kind, AgentPermissionKind.other);
      expect(request.summary, 'mcp__notion__create_page');
      expect(request.command, contains('title: Q3'));
    });

    test('the reply to our own handshake is not a request to answer', () {
      expect(
        parseClaudePermission({
          'type': 'control_response',
          'response': {'subtype': 'success', 'request_id': 'init'},
        }),
        isNull,
      );
    });

    test('yes hands the tool back its input unchanged; no says so in words the '
        'model can act on', () {
      final allow = claudePermissionResponse(
        requestId: 'r1',
        optionId: kAllowOnceOption,
        input: const {'command': 'ls'},
      );
      final response = (allow['response']! as Map)['response']! as Map;
      expect(response['behavior'], 'allow');
      expect(response['updatedInput'], const {'command': 'ls'});

      final deny = claudePermissionResponse(requestId: 'r1', optionId: null);
      expect(
        ((deny['response']! as Map)['response']! as Map)['behavior'],
        'deny',
      );
    });

    test('agreeing to one command is not agreeing to another', () {
      AgentPermission command(String line) => AgentPermission(
        id: 'x',
        kind: AgentPermissionKind.command,
        summary: line,
        command: line,
        options: claudePermissionOptions(AgentPermissionKind.command),
      );
      expect(
        claudePermissionGrantKey(command('rm -rf build')),
        isNot(claudePermissionGrantKey(command('rm -rf /'))),
      );
      expect(
        claudePermissionGrantKey(command('ls')),
        claudePermissionGrantKey(command('ls')),
      );
    });
  });
}
