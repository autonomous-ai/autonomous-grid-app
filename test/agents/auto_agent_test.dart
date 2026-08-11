import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/features/agents/logic/auto_agent.dart';

const _all = [
  AgentTool.hermes,
  AgentTool.codex,
  AgentTool.claude,
  AgentTool.pi,
];

void main() {
  group('the router prompt', () {
    test('lists every candidate id with its strengths, and asks for an id', () {
      final messages = buildRouterMessages('fix my build', const [
        AgentTool.hermes,
        AgentTool.codex,
      ]);
      final system = messages.first['content'] as String;
      // The classifier reasons over strengths, so each candidate's must be there.
      expect(system, contains('hermes: ${AgentTool.hermes.strengths}'));
      expect(system, contains('codex: ${AgentTool.codex.strengths}'));
      // A candidate that wasn't offered must not leak into the choice set.
      expect(system, isNot(contains('claude:')));
      // The reply is constrained to a bare id — the whole reason parsing is
      // reliable.
      expect(system, contains('one of: hermes, codex'));
      expect(messages.last, {'role': 'user', 'content': 'fix my build'});
    });
  });

  group('reading the router reply back to an agent', () {
    test('a bare id resolves, case-insensitively', () {
      expect(parseRoutedAgent('codex', _all), AgentTool.codex);
      expect(parseRoutedAgent('Claude', _all), AgentTool.claude);
    });

    test('an id inside a sentence still resolves', () {
      // Models ignore "id only" often enough that the parser must cope.
      expect(
        parseRoutedAgent("I'd use codex for this.", _all),
        AgentTool.codex,
      );
    });

    test('an id is matched as a whole word, not a substring', () {
      // "codexish" is not Codex, and reading it as such would misroute silently.
      expect(parseRoutedAgent('codexish thing', _all), isNull);
    });

    test('a reply naming two candidates is ambiguous, so neither wins', () {
      // An ambiguous answer is no answer; the caller falls back rather than
      // guessing which the model meant.
      expect(parseRoutedAgent('either hermes or codex', _all), isNull);
    });

    test('a reply naming none of the candidates resolves to null', () {
      expect(parseRoutedAgent('gpt-5', _all), isNull);
      expect(parseRoutedAgent('', _all), isNull);
    });

    test('only offered candidates are considered', () {
      // The grid may name an agent that isn't installed here; it must not be
      // routed to one the machine can't run.
      expect(
        parseRoutedAgent('claude', const [AgentTool.hermes, AgentTool.codex]),
        isNull,
      );
    });
  });

  group('the offline heuristic', () {
    test('one candidate needs no thought', () {
      expect(
        heuristicRoute('anything', const [AgentTool.hermes]),
        AgentTool.hermes,
      );
    });

    test('code-shaped work leans to a coding agent when one is available', () {
      expect(
        heuristicRoute('fix the null pointer bug in my code', _all),
        AgentTool.claude,
      );
      // Claude gone, Codex is the next coding preference.
      expect(
        heuristicRoute('refactor this function', const [
          AgentTool.hermes,
          AgentTool.codex,
        ]),
        AgentTool.codex,
      );
    });

    test('a plain question falls to the first candidate — the all-rounder', () {
      // The catalogue orders Hermes first precisely so this default is the
      // general-purpose one.
      expect(
        heuristicRoute('what is the capital of France?', _all),
        AgentTool.hermes,
      );
    });
  });

  test('the Auto sentinel is told apart from a real agent id', () {
    expect(isAutoAgentId('auto'), isTrue);
    expect(isAutoAgentId('hermes'), isFalse);
    expect(isAutoAgentId(null), isFalse);
    // It must not collide with any real agent's id.
    expect(AgentTool.values.map((a) => a.id), isNot(contains(kAutoAgentId)));
  });
}
