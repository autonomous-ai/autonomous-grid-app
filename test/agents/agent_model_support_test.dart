import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/hermes_grid_link.dart';
import 'package:grid_app/features/agents/logic/active_chat_agent.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/features/agents/logic/agent_model_support.dart';
import 'package:grid_app/features/playground/logic/playground_models.dart';
import 'package:grid_app/features/playground/logic/playground_request.dart';

/// A container whose open grid serves exactly [ids].
ProviderContainer _gridServing(List<String> ids) {
  final container = ProviderContainer(
    overrides: [
      playgroundModelsProvider.overrideWithValue([
        for (final id in ids)
          PlaygroundModelOption(
            id: id,
            label: id,
            modality: PlaygroundModality.text,
          ),
      ]),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group("an agent and a vendor's seat model have to match", () {
    test("Codex can't answer with a Claude seat's model — the pair reaches the "
        'grid as "no machine is serving a model Codex can use"', () {
      expect(agentSupportsModel(AgentTool.codex, 'claude:opus'), isFalse);
      expect(agentSupportsModel(AgentTool.codex, 'claude:sonnet'), isFalse);
    });

    test(
      "Claude Code can't answer with either Codex seat — one signs in with a "
      'ChatGPT subscription and the other with the CLI, and neither speaks '
      'Anthropic messages',
      () {
        expect(agentSupportsModel(AgentTool.claude, 'codex:gpt-5.5'), isFalse);
        expect(
          agentSupportsModel(AgentTool.claude, 'codex-cli:gpt-5.6-terra'),
          isFalse,
        );
      },
    );

    test('each agent still answers with its own seat', () {
      expect(agentSupportsModel(AgentTool.claude, 'claude:opus'), isTrue);
      expect(agentSupportsModel(AgentTool.codex, 'codex:gpt-5.5'), isTrue);
      expect(
        agentSupportsModel(AgentTool.codex, 'codex-cli:gpt-5.6-terra'),
        isTrue,
      );
    });

    test('Hermes answers with both CLI seats — they serve chat-completions, '
        'which is the dialect it speaks', () {
      expect(agentSupportsModel(AgentTool.hermes, 'claude:opus'), isTrue);
      expect(agentSupportsModel(AgentTool.hermes, 'codex-cli:gpt-5.5'), isTrue);
    });

    test("Hermes can't answer with a responses-only model: the shipped build "
        'resolves no config for it, and its Responses client omits the flags '
        'the relay requires', () {
      expect(agentSupportsModel(AgentTool.hermes, 'codex:gpt-5.5'), isFalse);
      // The same rule the config writer applies, so a greyed row and a written
      // config can never disagree about a model.
      expect(hermesModelRefusal('codex:gpt-5.5'), kHermesCannotServeCodexModel);
      expect(hermesModelRefusal('codex-cli:gpt-5.5'), isNull);
      expect(hermesModelRefusal('qwen3.6-27b'), isNull);
    });

    test(
      'a model nobody owns is open to every agent — a gguf on a machine, the '
      'router, an empty selection',
      () {
        for (final tool in AgentTool.values) {
          expect(agentSupportsModel(tool, 'qwen3.6-27b'), isTrue);
          expect(agentSupportsModel(tool, 'auto'), isTrue);
          expect(agentSupportsModel(tool, ''), isTrue);
        }
      },
    );

    test(
      'the kind is read case-insensitively, and out of every model in a '
      'comma-joined selection — one foreign model in a list still blocks',
      () {
        expect(agentSupportsModel(AgentTool.codex, 'Claude:Opus'), isFalse);
        expect(
          agentSupportsModel(AgentTool.codex, 'qwen3.6-27b, claude:opus'),
          isFalse,
        );
      },
    );

    test('a model whose *name* starts with a seat kind is not a seat model — '
        'the kind is what stands before the colon', () {
      expect(agentSupportsModel(AgentTool.codex, 'claude-clone-7b'), isTrue);
      expect(agentSupportsModel(AgentTool.claude, 'codexer/gguf-3b'), isTrue);
    });
  });

  group('who to switch to when the pair does not work', () {
    test('the agents offered for a model are the ones that can answer with it, '
        'so a blocked row can point somewhere real', () {
      expect(agentsForModel('claude:opus'), [
        AgentTool.hermes,
        AgentTool.claude,
      ]);
      expect(agentsForModel('codex:gpt-5.5'), [AgentTool.codex]);
      expect(agentsForModel('qwen3.6-27b'), AgentTool.values);
    });

    test('the blocked mark names the agent refusing, not the model', () {
      expect(agentModelBlockedLabel(AgentTool.codex), 'Not for Codex');
      expect(
        agentModelBlockedReason(AgentTool.codex),
        contains("Codex can't answer"),
      );
    });
  });

  group('whether a grid has anything an agent could answer with', () {
    test('a grid of Claude seat models has nothing for Codex — the note in the '
        'assistant picker is what stops the user picking a dead end', () {
      final container = _gridServing(['claude:opus', 'claude:sonnet']);
      expect(
        container.read(agentHasModelHereProvider(AgentTool.codex)),
        isFalse,
      );
      expect(
        container.read(agentHasModelHereProvider(AgentTool.claude)),
        isTrue,
      );
      expect(
        container.read(agentHasModelHereProvider(AgentTool.hermes)),
        isTrue,
      );
    });

    test('one model an agent can use is enough — the rest being foreign is the '
        "picker's problem, not the agent's", () {
      final container = _gridServing(['claude:opus', 'qwen3.6-27b']);
      expect(
        container.read(agentHasModelHereProvider(AgentTool.codex)),
        isTrue,
      );
    });

    test('a grid that has not answered yet lets every agent try — reading the '
        'empty list as "no" would flash a warning on every grid switch', () {
      final container = _gridServing(const []);
      for (final tool in AgentTool.values) {
        expect(container.read(agentHasModelHereProvider(tool)), isTrue);
      }
    });
  });

  group('a grid that serves only the ChatGPT-subscription seat', () {
    test('has something for Codex and nothing for the other two — the notice '
        'in the assistant picker is the only warning before a dead turn', () {
      final container = _gridServing(['codex:gpt-5.5']);
      expect(
        container.read(agentHasModelHereProvider(AgentTool.codex)),
        isTrue,
      );
      for (final tool in [AgentTool.hermes, AgentTool.claude]) {
        expect(
          container.read(agentHasModelHereProvider(tool)),
          isFalse,
          reason: '$tool has nothing to answer with here',
        );
      }
    });
  });
}
