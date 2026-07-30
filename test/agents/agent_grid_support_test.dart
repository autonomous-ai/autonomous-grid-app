import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/features/agents/logic/agent_grid_support.dart';
import 'package:grid_app/features/network/logic/client_app_grid_support.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';

/// A grid whose overview reports exactly these three dialect flags. Null is what
/// a relay that never mentioned a dialect leaves behind.
GridOverview _grid({bool? chat, bool? responses, bool? messages}) =>
    GridOverview(
      stats: const GridStats(models: 0, nodes: 0),
      models: const [],
      nodes: const [],
      advertisesChatCompletions: chat,
      advertisesResponses: responses,
      advertisesMessages: messages,
    );

void main() {
  group('which dialect each agent needs', () {
    test('each agent asks for the dialect its own program speaks', () {
      expect(agentDialect(AgentTool.codex), RelayDialect.responses);
      expect(agentDialect(AgentTool.claude), RelayDialect.messages);
      expect(agentDialect(AgentTool.hermes), RelayDialect.chatCompletions);
    });
  });

  group('which agents a grid can run', () {
    test('Codex needs a grid that answers on the Responses API', () {
      // Codex ≥ 0.141 rejects the chat-completions dialect outright, so a grid
      // that serves nothing on Responses has nothing it can talk to.
      expect(
        agentRunsOnGrid(AgentTool.codex, _grid(chat: true, responses: false)),
        isFalse,
      );
      expect(
        agentRunsOnGrid(AgentTool.codex, _grid(responses: true)),
        isTrue,
      );
    });

    test('Claude Code needs a grid that answers Anthropic messages — a grid '
        'serving only chat models has nothing it can talk to', () {
      expect(
        agentRunsOnGrid(AgentTool.claude, _grid(chat: true, messages: false)),
        isFalse,
      );
      expect(agentRunsOnGrid(AgentTool.claude, _grid(messages: true)), isTrue);
    });

    test('a Responses-only grid rules Claude out and Codex in — the two are '
        'not interchangeable', () {
      final grid = _grid(responses: true, messages: false);
      expect(agentRunsOnGrid(AgentTool.codex, grid), isTrue);
      expect(agentRunsOnGrid(AgentTool.claude, grid), isFalse);
    });

    test('Hermes runs on any grid — it speaks both dialects', () {
      // Hermes switches to `api_mode: responses` on a named provider when the
      // model needs it, so it is the agent that always has somewhere to go.
      for (final flag in <bool?>[true, false, null]) {
        expect(
          agentRunsOnGrid(AgentTool.hermes, _grid(chat: flag)),
          // Only an explicit false on its *own* dialect could stop it, and a
          // grid with no chat model is one nothing else could run on either.
          flag == false ? isFalse : isTrue,
        );
      }
    });

    test('a relay that never reported the flags lets every agent try', () {
      // Null is "the relay didn't say", not "no". Reading it as no would drop
      // every Codex user back to Hermes for the seconds before the overview
      // lands — and for good on any grid that doesn't ship the flags yet.
      for (final tool in AgentTool.values) {
        expect(agentRunsOnGrid(tool, _grid()), isTrue);
        expect(agentRunsOnGrid(tool, null), isTrue);
      }
    });

    test('the reason names the grid, not the agent', () {
      // The same Codex build answers fine on the next grid over, so the sentence
      // has to put the limitation where it belongs or the user goes looking for
      // a broken install.
      final reason = agentUnsupportedHere(AgentTool.codex);
      expect(reason, contains('This grid'));
      expect(reason, contains('Codex'));
    });
  });
}
