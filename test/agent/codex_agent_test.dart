import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/app_guide_snippets.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_app/infrastructure/cli/agent_version_service.dart';
import 'package:grid_app/infrastructure/cli/raw_agent_argv.dart';

void main() {
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
      final args = codexRawArgs(
        model: 'qwen3',
        workdir: '/tmp/project',
        approval: AgentApprovalMode.ask,
        config: overrides,
      );

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
