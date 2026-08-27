import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/adapters/codex_chat_sender.dart';
import 'package:grid_app/features/network/logic/app_guide_snippets.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_app/infrastructure/cli/agent_version_service.dart';
import 'package:grid_app/infrastructure/cli/codex_agent_service.dart';
import 'package:grid_app/infrastructure/cli/codex_app_server_parser.dart';
import 'package:grid_app/infrastructure/cli/codex_app_server_service.dart';
import 'package:grid_app/infrastructure/cli/codex_approval.dart';

void main() {
  group('the codex app-server stream, notification by notification', () {
    Map<String, String> answer() => <String, String>{};

    test('the opening thread carries the id to resume with later', () {
      final event = parseCodexAppServerEvent(
        method: 'thread/started',
        params: const {
          'thread': {'id': 'th-1'},
        },
        messages: answer(),
      );
      expect(event, isA<CodexThreadStarted>());
      expect((event! as CodexThreadStarted).threadId, 'th-1');
    });

    test('deltas build the answer as it is typed, and the finished block '
        'replaces them rather than doubling them', () {
      final messages = answer();
      parseCodexAppServerEvent(
        method: 'item/agentMessage/delta',
        params: const {'itemId': 'm1', 'delta': 'Hel'},
        messages: messages,
      );
      final streaming = parseCodexAppServerEvent(
        method: 'item/agentMessage/delta',
        params: const {'itemId': 'm1', 'delta': 'lo'},
        messages: messages,
      );
      expect((streaming! as CodexMessageEvent).text, 'Hello');

      final whole = parseCodexAppServerEvent(
        method: 'item/completed',
        params: const {
          'item': {'type': 'agentMessage', 'id': 'm1', 'text': 'Hello there'},
        },
        messages: messages,
      );
      expect((whole! as CodexMessageEvent).text, 'Hello there');
    });

    test('two messages in one turn are joined, not overwritten', () {
      final messages = answer();
      parseCodexAppServerEvent(
        method: 'item/completed',
        params: const {
          'item': {'type': 'agentMessage', 'id': 'm1', 'text': 'First'},
        },
        messages: messages,
      );
      final second = parseCodexAppServerEvent(
        method: 'item/completed',
        params: const {
          'item': {'type': 'agentMessage', 'id': 'm2', 'text': 'Second'},
        },
        messages: messages,
      );
      expect((second! as CodexMessageEvent).text, 'First\n\nSecond');
    });

    test('a command step keeps its live status — this protocol spells it '
        'inProgress, and reading it as unknown would show every finished '
        'command as still running', () {
      final running = parseCodexAppServerEvent(
        method: 'item/started',
        params: const {
          'item': {
            'type': 'commandExecution',
            'id': 'c1',
            'command': 'ls -la',
            'status': 'inProgress',
          },
        },
        messages: answer(),
      );
      final activity = (running! as CodexActivityEvent).activity;
      expect(activity.kind, AgentActivityKind.command);
      expect(activity.label, 'ls -la');
      expect(activity.status, AgentActivityStatus.running);

      final done = parseCodexAppServerEvent(
        method: 'item/completed',
        params: const {
          'item': {
            'type': 'commandExecution',
            'id': 'c1',
            'command': 'ls -la',
            'status': 'completed',
            'aggregatedOutput': 'a\nb',
          },
        },
        messages: answer(),
      );
      expect(
        (done! as CodexActivityEvent).activity.status,
        AgentActivityStatus.done,
      );
      expect((done as CodexActivityEvent).activity.result, contains('a'));
    });

    test('a plan revision replaces the to-do list, blanks dropped', () {
      final event = parseCodexAppServerEvent(
        method: 'turn/plan/updated',
        params: const {
          'plan': [
            {'step': 'Read the file', 'status': 'completed'},
            {'step': 'Fix it', 'status': 'inProgress'},
            {'step': '  ', 'status': 'pending'},
          ],
        },
        messages: answer(),
      );
      final entries = (event! as CodexPlanEvent).entries;
      expect(entries.length, 2);
      expect(entries.first.status, AgentPlanStatus.done);
      expect(entries.last.status, AgentPlanStatus.active);
    });

    test('a turn that ends badly says so; one that simply ends does not', () {
      final failed = parseCodexAppServerEvent(
        method: 'turn/completed',
        params: const {
          'turn': {
            'status': 'failed',
            'error': {'message': 'the grid refused'},
          },
        },
        messages: answer(),
      );
      expect((failed! as CodexTurnFailed).message, 'the grid refused');
      expect(
        parseCodexAppServerEvent(
          method: 'turn/completed',
          params: const {
            'turn': {'status': 'completed'},
          },
          messages: answer(),
        ),
        isA<CodexTurnCompleted>(),
      );
    });

    test('an error Codex will retry is a reconnect notice, not a dead turn — '
        'reporting it would put a failure over a turn that goes on to '
        'answer', () {
      expect(
        parseCodexAppServerEvent(
          method: 'error',
          params: const {
            'willRetry': true,
            'error': {'message': 'stream dropped'},
          },
          messages: answer(),
        ),
        isNull,
      );
      expect(
        parseCodexAppServerEvent(
          method: 'error',
          params: const {
            'willRetry': false,
            'error': {'message': 'stream dropped'},
          },
          messages: answer(),
        ),
        isA<CodexTurnFailed>(),
      );
    });

    test('a helper agent\'s turn ending is not ours ending — its '
        'turn/completed arrived 2s before the parent\'s answer and used to '
        'kill the server mid-reply', () {
      final messages = answer();
      final helper = parseCodexAppServerEvent(
        method: 'turn/completed',
        params: const {
          'threadId': 'helper-1',
          'turn': {'status': 'completed'},
        },
        messages: messages,
        thread: 'main',
      );
      final own = parseCodexAppServerEvent(
        method: 'turn/completed',
        params: const {
          'threadId': 'main',
          'turn': {'status': 'completed'},
        },
        messages: messages,
        thread: 'main',
      );
      expect(helper, isNull);
      expect(own, isA<CodexTurnCompleted>());
    });

    test('a helper\'s message is a note under the call that spawned it, never '
        'part of the answer; its steps nest there too', () {
      final messages = answer();
      final agents = <String, String>{};
      final spawn = parseCodexAppServerEvent(
        method: 'item/completed',
        params: const {
          'threadId': 'main',
          'item': {
            'type': 'collabAgentToolCall',
            'id': 'c1',
            'tool': 'spawnAgent',
            'status': 'completed',
            'prompt': 'Reply with only the word ok',
            'receiverThreadIds': ['helper-1'],
            'agentsStates': {'helper-1': 'running'},
          },
        },
        messages: messages,
        thread: 'main',
        agents: agents,
      );
      final row = (spawn! as CodexActivityEvent).activity;
      expect(row.label, 'Started a helper agent');
      expect(row.request, 'Reply with only the word ok');
      expect(row.result, 'helper-1: running');
      expect(agents, {'helper-1': 'c1'});

      final said = parseCodexAppServerEvent(
        method: 'item/completed',
        params: const {
          'threadId': 'helper-1',
          'item': {'type': 'agentMessage', 'id': 'm-h', 'text': 'ok'},
        },
        messages: messages,
        thread: 'main',
        agents: agents,
      );
      final note = (said! as CodexActivityEvent).activity;
      expect(note.kind, AgentActivityKind.thinking);
      expect(note.label, 'ok');
      expect(note.parent, 'c1');
      expect(messages, isEmpty);

      final ran = parseCodexAppServerEvent(
        method: 'item/started',
        params: const {
          'threadId': 'helper-1',
          'item': {
            'type': 'commandExecution',
            'id': 'x1',
            'command': 'sleep 1',
            'status': 'inProgress',
          },
        },
        messages: messages,
        thread: 'main',
        agents: agents,
      );
      expect((ran! as CodexActivityEvent).activity.parent, 'c1');
    });

    test('with no thread known — an older build, or the tests above — every '
        'notification is read as ours, exactly as before', () {
      final event = parseCodexAppServerEvent(
        method: 'item/completed',
        params: const {
          'threadId': 'whatever',
          'item': {'type': 'agentMessage', 'id': 'm1', 'text': 'Hi'},
        },
        messages: answer(),
      );
      expect((event! as CodexMessageEvent).text, 'Hi');
    });

    test('reasoning is shown as a thought — the summary when the model sends '
        'one, the content when a grid model streams it whole — and an empty '
        'one is nothing', () {
      final full = parseCodexAppServerEvent(
        method: 'item/completed',
        params: const {
          'item': {
            'type': 'reasoning',
            'id': 'r1',
            'summary': [],
            'content': ['The user wants me to spawn a sub-agent.'],
          },
        },
        messages: answer(),
      );
      final thought = (full! as CodexActivityEvent).activity;
      expect(thought.kind, AgentActivityKind.thinking);
      expect(thought.label, 'The user wants me to spawn a sub-agent.');
      expect(
        parseCodexAppServerEvent(
          method: 'item/started',
          params: const {
            'item': {
              'type': 'reasoning',
              'id': 'r2',
              'summary': [],
              'content': [],
            },
          },
          messages: answer(),
        ),
        isNull,
      );
    });

    test('the items the CLI draws and the chat used to drop each get a row in '
        'the user\'s words', () {
      String label(Map<String, Object?> item) =>
          (parseCodexAppServerEvent(
                    method: 'item/completed',
                    params: {'item': item},
                    messages: answer(),
                  )!
                  as CodexActivityEvent)
              .activity
              .label;

      expect(
        label({'type': 'imageView', 'id': 'i', 'path': '/a.png'}),
        'Looked at /a.png',
      );
      expect(
        label({'type': 'sleep', 'id': 's', 'durationMs': 2500}),
        'Waited 3s',
      );
      expect(
        label({'type': 'contextCompaction', 'id': 'c'}),
        'Made room in the conversation',
      );
      expect(
        label({'type': 'enteredReviewMode', 'id': 'e', 'review': 'r'}),
        'Started a review',
      );
      expect(
        label({'type': 'plan', 'id': 'p', 'text': 'First, look.'}),
        'First, look.',
      );
      expect(
        label({
          'type': 'collabAgentToolCall',
          'id': 'w',
          'tool': 'wait',
          'status': 'inProgress',
        }),
        'Waited for helper agents',
      );
    });

    test('the prompt we just sent, the turn opening, and a notification from a '
        'later build all surface nothing', () {
      for (final method in ['turn/started', 'thread/tokenUsage/updated']) {
        expect(
          parseCodexAppServerEvent(
            method: method,
            params: const {},
            messages: answer(),
          ),
          isNull,
        );
      }
      expect(
        parseCodexAppServerEvent(
          method: 'item/completed',
          params: const {
            'item': {'type': 'userMessage', 'id': 'u1'},
          },
          messages: answer(),
        ),
        isNull,
      );
    });
  });

  group('the approval channel — the reason this transport exists', () {
    test('what the chat may do is what the composer said, and full access is '
        'now a choice rather than the only setting there was', () {
      expect(
        codexApprovalPolicy(AgentApprovalMode.readOnly).sandbox,
        'read-only',
      );
      expect(codexApprovalPolicy(AgentApprovalMode.ask).policy, 'untrusted');
      expect(
        codexApprovalPolicy(AgentApprovalMode.ask).sandbox,
        'workspace-write',
      );
      expect(
        codexApprovalPolicy(AgentApprovalMode.full).sandbox,
        'danger-full-access',
      );
      // Nothing may be touched, so nothing can be escalated into a card.
      expect(codexApprovalPolicy(AgentApprovalMode.readOnly).policy, 'never');
    });

    test('a command reaches the user as the exact line Codex would run', () {
      final request = parseCodexApproval(
        id: 7,
        method: kCodexCommandApproval,
        params: const {
          'command': "/bin/zsh -lc \"printf 'hi' > out.txt\"",
          'cwd': '/tmp',
          'availableDecisions': ['accept', 'acceptForSession', 'decline'],
        },
      );
      expect(request!.kind, AgentPermissionKind.command);
      expect(request.command, contains('out.txt'));
      expect(request.id, 7);
      expect(request.canAllowForChat, isTrue);
    });

    test('only the answers Codex says it will take are offered — a button the '
        'server would reject is a button that does nothing', () {
      final request = parseCodexApproval(
        id: 1,
        method: kCodexCommandApproval,
        params: const {
          'command': 'ls',
          'availableDecisions': ['accept', 'decline'],
        },
      );
      expect(request!.canAllowForChat, isFalse);
      expect(request.options.map((o) => o.optionId), ['accept', 'decline']);
    });

    test('a patch is shown as the patch, over the files it touches — there is '
        'no honest before/after without applying it', () {
      final request = parseCodexApproval(
        id: 2,
        method: kCodexFileChangeApproval,
        params: const {'itemId': 'f1'},
        item: const {
          'type': 'fileChange',
          'id': 'f1',
          'changes': [
            {'path': 'lib/a.dart', 'kind': 'update', 'diff': '@@ -1 +1 @@'},
          ],
        },
      );
      expect(request!.kind, AgentPermissionKind.other);
      expect(request.summary, 'Change lib/a.dart');
      expect(request.command, contains('@@ -1 +1 @@'));
    });

    test('the chat-wide yes is handed back as the one Codex knows, so the chat '
        'and the thread agree on what was granted', () {
      expect(codexDecisionFor(kAllowForChatOption), kCodexAcceptForSession);
      expect(codexDecisionFor(kCodexAccept), kCodexAccept);
      // No answer at all is a no — never a yes by default.
      expect(codexDecisionFor(null), kCodexDecline);
      expect(
        codexApprovalResult(method: kCodexCommandApproval, optionId: null),
        {'decision': kCodexDecline},
      );
    });

    test('a request this app has no answer for is not answered with a yes', () {
      expect(
        parseCodexApproval(
          id: 3,
          method: 'item/permissions/requestApproval',
          params: const {},
        ),
        isNull,
      );
    });
  });

  group('codexAppServerArgs — a mistyped flag fails like a mute model', () {
    test('the turn runs a stdio server carrying the grid overrides', () {
      final args = codexAppServerArgs(config: const ['model="auto"']);
      expect(args.first, 'app-server');
      expect(args, contains('--stdio'));
      expect(args, containsAllInOrder(['-c', 'model="auto"']));
    });

    test('the sandbox is no longer nailed to the command line — it follows the '
        "chat's mode now, per thread", () {
      expect(
        codexAppServerArgs(config: const []).join(' '),
        isNot(contains('sandbox')),
      );
    });

    test('a Codex too old to ask says so, in a sentence naming the fix — '
        'falling back to the transport that could not ask would be the app '
        'promising to ask and then not asking', () {
      expect(
        codexStartupFailure('error: unrecognized subcommand \'app-server\'', 2),
        kCodexTooOld,
      );
      expect(
        codexStartupFailure('panicked at foo.rs', 101),
        'panicked at foo.rs',
      );
      expect(codexStartupFailure('', 1), contains('code 1'));
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
      final args = codexAppServerArgs(config: overrides);

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
