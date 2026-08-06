import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/adapters/codex_chat_sender.dart';
import 'package:grid_app/features/network/logic/app_guide_snippets.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_app/infrastructure/cli/agent_version_service.dart';
import 'package:grid_app/infrastructure/cli/codex_exec_service.dart';

void main() {
  group('parseCodexEvent — the codex exec --json thread stream', () {
    test('the opening thread.started carries the id to resume with later', () {
      final event = parseCodexEvent({
        'type': 'thread.started',
        'thread_id': 'abc-123',
      }, {});
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
      final event = parseCodexEvent({
        'type': 'error',
        'message': 'Reconnecting... 1/5',
      }, {});
      expect(event, isNull);
    });

    test('reasoning becomes a thinking step, so a pause reads as work', () {
      final event = parseCodexEvent({
        'type': 'item.started',
        'item': {
          'id': 'r1',
          'type': 'reasoning',
          'text': 'Checking where the file lives',
          'status': 'in_progress',
        },
      }, {});
      final activity = (event as CodexActivityEvent).activity;
      expect(activity.kind, AgentActivityKind.thinking);
      expect(activity.label, 'Checking where the file lives');
      expect(activity.status, AgentActivityStatus.running);
    });

    test('reasoning carried as a summary list is read too', () {
      final event = parseCodexEvent({
        'type': 'item.completed',
        'item': {
          'id': 'r2',
          'type': 'reasoning',
          'summary': [
            {'text': 'First I will read the files'},
          ],
        },
      }, {});
      expect(
        (event as CodexActivityEvent).activity.label,
        'First I will read the files',
      );
    });

    test('an empty reasoning item carries nothing to show', () {
      expect(
        parseCodexEvent({
          'type': 'item.completed',
          'item': {'id': 'r3', 'type': 'reasoning', 'text': '   '},
        }, {}),
        isNull,
      );
    });

    test(
      'turn.completed says the turn ended by itself — the chat reads it to tell '
      'a finished turn from one cut off mid-plan',
      () {
        expect(
          parseCodexEvent({'type': 'turn.completed'}, {}),
          isA<CodexTurnCompleted>(),
        );
      },
    );

    test('turn lifecycle chatter and unknown items surface nothing', () {
      expect(parseCodexEvent({'type': 'turn.started'}, {}), isNull);
      expect(
        parseCodexEvent({
          'type': 'item.completed',
          'item': {'id': 'x1', 'type': 'reasoning_summary'},
        }, {}),
        isNull,
      );
    });
  });

  group('file_change — so a file Codex writes becomes openable', () {
    test('a completed add surfaces the created file for the chat to open', () {
      final event = parseCodexEvent({
        'type': 'item.completed',
        'item': {
          'id': 'f1',
          'type': 'file_change',
          'status': 'completed',
          'changes': [
            {'path': '/tmp/ws/tank1990.html', 'kind': 'add'},
          ],
        },
      }, {});
      expect(event, isA<CodexFileChangeEvent>());
      final change = (event as CodexFileChangeEvent).changes.single;
      expect(change.path, '/tmp/ws/tank1990.html');
      expect(change.kind, CodexFileChangeKind.add);
    });

    test(
      'an in-flight apply has written nothing yet, so it surfaces nothing',
      () {
        expect(
          parseCodexEvent({
            'type': 'item.started',
            'item': {
              'id': 'f1',
              'type': 'file_change',
              'status': 'in_progress',
              'changes': [
                {'path': '/tmp/a.txt', 'kind': 'add'},
              ],
            },
          }, {}),
          isNull,
        );
      },
    );

    test('a file_change carrying no usable path surfaces nothing', () {
      expect(
        parseCodexEvent({
          'type': 'item.completed',
          'item': {
            'id': 'f1',
            'type': 'file_change',
            'status': 'completed',
            'changes': [],
          },
        }, {}),
        isNull,
      );
    });

    test('every kind is parsed faithfully, add / update / delete alike', () {
      final event =
          parseCodexEvent({
                'type': 'item.completed',
                'item': {
                  'id': 'f1',
                  'type': 'file_change',
                  'status': 'completed',
                  'changes': [
                    {'path': '/tmp/new.html', 'kind': 'add'},
                    {'path': '/tmp/old.dart', 'kind': 'update'},
                    {'path': '/tmp/gone.txt', 'kind': 'delete'},
                  ],
                },
              }, {})
              as CodexFileChangeEvent;
      expect(event.changes.map((c) => c.kind), [
        CodexFileChangeKind.add,
        CodexFileChangeKind.update,
        CodexFileChangeKind.delete,
      ]);
    });

    test('only created files are recorded — an edit or a delete has no honest '
        'before to diff or undo', () {
      const changes = [
        (path: '/tmp/new.html', kind: CodexFileChangeKind.add),
        (path: '/tmp/old.dart', kind: CodexFileChangeKind.update),
        (path: '/tmp/gone.txt', kind: CodexFileChangeKind.delete),
      ];
      expect(codexAddedPaths(changes), ['/tmp/new.html']);
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

  group('codexExecArgs — the two subcommands take different flags', () {
    test('a first turn runs in the folder it was given', () {
      final args = codexExecArgs(workdir: '/tmp/work', config: const []);

      expect(args.first, 'exec');
      expect(args, isNot(contains('resume')));
      expect(args, containsAllInOrder(['-C', '/tmp/work']));
    });

    test('a resumed turn passes no flag `exec resume` would reject — one '
        'unknown flag kills the turn before the model is ever reached', () {
      final args = codexExecArgs(
        workdir: '/tmp/work',
        config: const [],
        resumeThreadId: 'abc',
      );

      expect(args, containsAllInOrder(['exec', 'resume']));
      expect(args.last, 'abc');
      expect(args, isNot(contains('--sandbox')));
      expect(args, isNot(contains('-C')));
      expect(args, isNot(contains('/tmp/work')));
    });

    test('both turns carry the sandbox mode, said the one way both subcommands '
        'take — `--sandbox` kills `exec resume` at argv parsing', () {
      for (final args in [
        codexExecArgs(workdir: '/tmp/work', config: const []),
        codexExecArgs(
          workdir: '/tmp/work',
          config: const [],
          resumeThreadId: 'abc',
        ),
      ]) {
        expect(args, isNot(contains('--sandbox')));
        expect(
          args,
          containsAllInOrder(['-c', 'sandbox_mode="$kCodexSandboxMode"']),
        );
        expect(args, contains('--json'));
      }
    });

    test('the grid the app picked rides on every turn, resumed ones too — a '
        'resumed session does not restore the model it was recorded with, so '
        'a turn without it answers as a model nobody chose', () {
      final config = codexGridOverrides(
        base: 'https://relay.example/relay/v1',
        model: 'qwen3',
      );

      for (final args in [
        codexExecArgs(workdir: '/tmp/work', config: config),
        codexExecArgs(
          workdir: '/tmp/work',
          config: config,
          resumeThreadId: 'abc',
        ),
      ]) {
        for (final override in config) {
          expect(args, containsAllInOrder(['-c', override]));
        }
        expect(args, contains('model="qwen3"'));
      }
    });

    test("the user's own config is still loaded, because their MCP servers "
        'live in it — dropping it would take every connector away from an '
        'in-app turn without saying so', () {
      final args = codexExecArgs(
        workdir: '/tmp/work',
        config: codexGridOverrides(base: 'https://relay', model: 'qwen3'),
      );

      expect(args, isNot(contains('--ignore-user-config')));
    });
  });

  group('codexGridOverrides — the grid, handed over per run', () {
    const base = 'https://relay.example/relay/v1';
    final overrides = codexGridOverrides(base: base, model: 'qwen3');

    test('the provider it defines is the app\'s own, never the id the guide '
        "writes into the user's file — one is theirs to keep, the other "
        'exists for the length of one run', () {
      expect(kCodexAppProviderId, isNot(kCodexProviderId));
      expect(overrides, contains('model_provider="$kCodexAppProviderId"'));
      expect(
        overrides,
        contains('model_providers.$kCodexAppProviderId.base_url="$base"'),
      );
    });

    test('the provider is named — Codex refuses to load the whole config over '
        'an empty provider name, before the model is ever reached', () {
      final name = overrides.firstWhere(
        (o) => o.startsWith('model_providers.$kCodexAppProviderId.name='),
      );
      expect(name, 'model_providers.$kCodexAppProviderId.name="Grid"');
    });

    test('the key is read from a variable the dotenv cannot shadow — Codex '
        "loads ~/.codex/.env itself and it beats the app's environment, so a "
        'stale key left there by an older build would outrank the live one', () {
      expect(kCodexAppApiKeyEnv, isNot(gridApiKeyEnv));
      expect(
        overrides,
        contains(
          'model_providers.$kCodexAppProviderId.env_key="$kCodexAppApiKeyEnv"',
        ),
      );
    });

    test('the credential itself never reaches the command line', () {
      final args = codexExecArgs(workdir: '/tmp/work', config: overrides);

      expect(args.join(' '), isNot(contains('secret-key')));
      expect(overrides.join(' '), isNot(contains('secret-key')));
    });

    test('it speaks the only dialect Codex still accepts', () {
      expect(
        overrides,
        contains('model_providers.$kCodexAppProviderId.wire_api="responses"'),
      );
    });
  });

  group('friendlyCodexError — a next step, not a stack trace', () {
    test('the responses wall reads as a limit of the model that was picked, '
        'not of Codex or of the grid as a whole', () {
      // A grid that can't run Codex at all never gets handed the chat, so what
      // is left when this fires is the model. Naming the grid instead sent
      // people hunting for a different one while theirs served Codex fine.
      final message = friendlyCodexError(
        'stream disconnected before completion: error sending request for url '
        '(http://host/v1/responses)',
      );
      expect(message, kCodexDialectFailure);
      expect(message.toLowerCase(), contains('this model'));
    });

    test('a grid with nobody serving the model reads as an empty grid, not as '
        'a wrong model — the two have different fixes', () {
      // The real 503 a user hits: the endpoint is there and understood the
      // request, there is just no machine behind it. Told as "wrong model" it
      // sends them renaming models while the grid is simply empty.
      final message = friendlyCodexError(
        'unexpected status 503 Service Unavailable: {"detail":"No providers '
        'available for this model"}, url: https://grid.autonomous.ai/'
        'grid-3378218621364f16/relay/v1/responses',
      );
      expect(message, kCodexNoProviderFailure);
      expect(message, isNot(contains('503')));
    });

    test('neither responses message promises another agent by name — the chat '
        'offers the swap as a button, which is a try, not a promise', () {
      for (final message in [kCodexDialectFailure, kCodexNoProviderFailure]) {
        expect(message, isNot(contains('Hermes')));
      }
    });

    test('a failure that never reached the Responses call keeps codex own '
        'words, rather than being read as a grid problem', () {
      expect(
        friendlyCodexError('unexpected status 503 Service Unavailable'),
        contains('503'),
      );
    });

    test('any other failure keeps codex own last line', () {
      expect(
        friendlyCodexError('boom\nauthentication failed'),
        contains('authentication failed'),
      );
    });

    test('a rejected command quotes the reason, not the usage footer codex '
        'prints under it', () {
      final message = friendlyCodexError(
        "error: unexpected argument '--sandbox' found\n\n"
        'Usage: codex exec resume --json <SESSION_ID> [PROMPT]\n\n'
        "For more information, try '--help'.",
      );

      expect(message, contains("unexpected argument '--sandbox'"));
      expect(message, isNot(contains('--help')));
    });

    test('a silent failure still says what to do', () {
      expect(friendlyCodexError('   '), contains('try again'));
    });
  });

  group('agentPlanUnfinished — a stalled turn must not read as an answer', () {
    AgentPlanEntry step(String content, AgentPlanStatus status) =>
        AgentPlanEntry(content: content, status: status);

    test('a plan with a step still pending stopped short of its own work', () {
      // The tank-game turn: it announced steps, ticked none off, then ended —
      // the chat used to show that as a success with a bare "let me write it".
      expect(
        agentPlanUnfinished([
          step('Design the game', AgentPlanStatus.pending),
          step('Write the file', AgentPlanStatus.pending),
          step('Verify it runs', AgentPlanStatus.pending),
        ]),
        isTrue,
      );
    });

    test('a step left active mid-flight is unfinished too', () {
      expect(
        agentPlanUnfinished([step('Writing the file', AgentPlanStatus.active)]),
        isTrue,
      );
    });

    test('every step done is a finished plan — a real answer, not a stall', () {
      expect(
        agentPlanUnfinished([
          step('Read the files', AgentPlanStatus.done),
          step('Write the answer', AgentPlanStatus.done),
        ]),
        isFalse,
      );
    });

    test(
      'no plan is not an unfinished one — a plain answer never made one',
      () {
        expect(agentPlanUnfinished(const []), isFalse);
      },
    );
  });

  group('agentTurnStalled — an unticked box is not a failed turn', () {
    AgentPlanEntry step(String content, AgentPlanStatus status) =>
        AgentPlanEntry(content: content, status: status);

    final unfinished = [
      step('Fetch the thread', AgentPlanStatus.done),
      step('Extract the comments', AgentPlanStatus.active),
      step('Summarize the themes', AgentPlanStatus.pending),
    ];

    test(
      'a turn that worked on its plan and ended by itself answered, whatever '
      'the boxes say',
      () {
        // The Reddit turn: it browsed, pulled 51 comments, summarized them all,
        // and never revisited its to-do list. Read off the plan alone, that had
        // the chat put "stopped before finishing" under a finished answer and
        // offer to hand the work to another agent.
        expect(
          agentTurnStalled(
            plan: unfinished,
            endedCleanly: true,
            workedAtAll: true,
            planFirst: false,
          ),
          isFalse,
        );
      },
    );

    test('work done before the closing plan revision still counts, since ticking '
        'the boxes last is the normal rhythm', () {
      // The review turn: 66 commands, then one update_plan marking five of six
      // steps done, then the review itself — no tool call after the plan. Read
      // as "did it work *since* the plan?", every command it had run counted
      // for nothing and a finished review came back as a stall.
      final closing = [
        step('Read the changed files', AgentPlanStatus.done),
        step('Run analyze and the tests', AgentPlanStatus.done),
        step('Write the review', AgentPlanStatus.active),
      ];
      expect(
        agentTurnStalled(
          plan: closing,
          endedCleanly: true,
          workedAtAll: true,
          planFirst: false,
        ),
        isFalse,
      );
    });

    test('a turn that announced steps and ran none of them stalled', () {
      // The tank-game turn: a plan, "let me write it for you", nothing built.
      expect(
        agentTurnStalled(
          plan: unfinished,
          endedCleanly: true,
          workedAtAll: false,
          planFirst: false,
        ),
        isTrue,
      );
    });

    test('a turn cut short leaves its open steps undone, work or no work', () {
      expect(
        agentTurnStalled(
          plan: unfinished,
          endedCleanly: false,
          workedAtAll: true,
          planFirst: false,
        ),
        isTrue,
      );
    });

    test('a plan with every step ticked off is an answer either way', () {
      final done = [
        step('Read the files', AgentPlanStatus.done),
        step('Write the answer', AgentPlanStatus.done),
      ];
      expect(
        agentTurnStalled(
          plan: done,
          endedCleanly: false,
          workedAtAll: false,
          planFirst: false,
        ),
        isFalse,
      );
    });

    test('in planning mode an unfinished plan is the point, never a stall', () {
      expect(
        agentTurnStalled(
          plan: unfinished,
          endedCleanly: false,
          workedAtAll: false,
          planFirst: true,
        ),
        isFalse,
      );
    });
  });

  group('agentSpentToolBudget — stopped for want of room, not of work', () {
    AgentPlanEntry step(String content, AgentPlanStatus status) =>
        AgentPlanEntry(content: content, status: status);

    final unfinished = [
      step('Idempotency for the webhook', AgentPlanStatus.done),
      step('Update the architecture doc', AgentPlanStatus.active),
      step('Verify and commit', AgentPlanStatus.pending),
    ];

    test('a turn that used every call it had and left steps open ran out of '
        'room — the case a user reads as "it keeps stopping halfway"', () {
      // The 2026-08-06 turn: 95 tool calls against a budget of 90, plan at 3/5,
      // and the agent's runtime called it a clean end_turn like any other.
      expect(
        agentSpentToolBudget(toolCalls: 95, budget: 90, plan: unfinished),
        isTrue,
      );
    });

    test('a turn still inside its budget stopped for some other reason, and '
        'must not be explained away by this one', () {
      expect(
        agentSpentToolBudget(toolCalls: 12, budget: 90, plan: unfinished),
        isFalse,
      );
    });

    test('a finished plan is never reported as cut short, however many tools it '
        'took to get there', () {
      final done = [
        step('Idempotency for the webhook', AgentPlanStatus.done),
        step('Verify and commit', AgentPlanStatus.done),
      ];
      // The count is tool calls while the budget counts model round-trips, so a
      // busy finished turn can pass the number without ever hitting the cap.
      expect(
        agentSpentToolBudget(toolCalls: 200, budget: 90, plan: done),
        isFalse,
      );
    });

    test('no budget means no verdict — an agent with no cap can never hit '
        'one', () {
      expect(
        agentSpentToolBudget(toolCalls: 95, budget: 0, plan: unfinished),
        isFalse,
      );
    });
  });

  group('isAgentWork — thinking about the step is not doing it', () {
    AgentActivity activity(AgentActivityKind kind) => AgentActivity(
      id: 'a1',
      kind: kind,
      label: 'x',
      status: AgentActivityStatus.done,
    );

    test('a command, a look-up or a tool call is work on the plan', () {
      expect(isAgentWork(activity(AgentActivityKind.command)), isTrue);
      expect(isAgentWork(activity(AgentActivityKind.web)), isTrue);
      expect(isAgentWork(activity(AgentActivityKind.tool)), isTrue);
    });

    test('the model reasoning about what to do next is not', () {
      expect(isAgentWork(activity(AgentActivityKind.thinking)), isFalse);
    });
  });
}
