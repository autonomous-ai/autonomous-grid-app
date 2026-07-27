import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/agent_registry.dart';
import 'package:grid_app/features/agents/logic/agent_grid_support.dart';

void main() {
  final codex = agentById('codex')!;
  final hermes = agentById('hermes')!;

  group('which agents a grid can run', () {
    test('Codex needs a grid that answers on the Responses API', () {
      // Codex ≥ 0.141 rejects the chat-completions dialect outright, so a grid
      // that serves nothing on Responses has nothing it can talk to.
      expect(codex.needsResponses, isTrue);
      expect(agentRunsOnGrid(codex, advertisesResponses: false), isFalse);
      expect(agentRunsOnGrid(codex, advertisesResponses: true), isTrue);
    });

    test('Hermes runs on any grid — it speaks both dialects', () {
      // Hermes switches to `api_mode: responses` on a named provider when the
      // model needs it, so it is the agent that always has somewhere to go.
      expect(hermes.needsResponses, isFalse);
      for (final flag in <bool?>[true, false, null]) {
        expect(agentRunsOnGrid(hermes, advertisesResponses: flag), isTrue);
      }
    });

    test('a relay that never reported the flag lets Codex try anyway', () {
      // Null is "the relay didn't say", not "no". Reading it as no would drop
      // every Codex user back to Hermes for the seconds before the overview
      // lands — and for good on any grid that doesn't ship the flag yet.
      expect(agentRunsOnGrid(codex, advertisesResponses: null), isTrue);
    });

    test('the reason names the grid, not the agent', () {
      // The same Codex build answers fine on the next grid over, so the sentence
      // has to put the limitation where it belongs or the user goes looking for
      // a broken install.
      final reason = agentUnsupportedHere(codex);
      expect(reason, contains('This grid'));
      expect(reason, contains('Codex'));
    });
  });
}
