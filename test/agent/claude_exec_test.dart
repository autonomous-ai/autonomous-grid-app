import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/adapters/claude_chat_sender.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_app/infrastructure/cli/agent_question.dart';
import 'package:grid_app/infrastructure/cli/claude_exec_event.dart';
import 'package:grid_app/infrastructure/cli/claude_exec_service.dart';
import 'package:grid_app/infrastructure/cli/claude_permission.dart';
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

    test('every turn takes away the session-only schedulers, which would '
        'report a job scheduled and then never fire it', () {
      final args = claudeExecArgs(model: 'm');
      final flag = args.indexOf('--disallowedTools');
      expect(flag, isNot(-1));
      expect(
        args.sublist(flag + 1, flag + 1 + kClaudeSessionSchedulerTools.length),
        kClaudeSessionSchedulerTools,
      );
    });

    test('the wake-up timer goes with the cron tools: it is the one an agent '
        'reaches for when asked for a loop, and it dies with the turn', () {
      expect(kClaudeSessionSchedulerTools, contains('ScheduleWakeup'));
    });

    test('a relay turn drops the web tools onto that same flag — a second '
        '--disallowedTools would be the CLI\'s to reconcile', () {
      final args = claudeExecArgs(model: 'm', withoutServerWebTools: true);
      expect(args.where((a) => a == '--disallowedTools'), hasLength(1));
      final flag = args.indexOf('--disallowedTools');
      expect(
        args.sublist(
          flag + 1,
          flag +
              1 +
              kClaudeSessionSchedulerTools.length +
              kClaudeServerWebTools.length,
        ),
        [...kClaudeSessionSchedulerTools, ...kClaudeServerWebTools],
      );
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
          claudeToolLabel('Agent', const {
            'description': 'Review the diff',
            'subagent_type': 'code-reviewer',
          }),
          'Agent · Review the diff',
        );
        // The older name still answers, since the app pins no CLI version.
        expect(
          claudeToolLabel('Task', const {'description': 'Review the diff'}),
          'Task · Review the diff',
        );
      },
    );

    test('a skill row names the skill that ran', () {
      expect(
        claudeToolLabel('Skill', const {
          'skill': 'grid-web',
          'args': 'flutter',
        }),
        'Skill · grid-web',
      );
    });

    test('a connector row drops the wire identifier for the server and tool '
        'behind it — a row spent entirely on `mcp__…__…` names nothing the '
        'user chose', () {
      expect(
        claudeToolLabel('mcp__gitnexus__impact', const {'target': 'ChatStore'}),
        'gitnexus · impact · ChatStore',
      );
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
