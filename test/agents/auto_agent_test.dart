import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/adapters/claude_tool.dart';
import 'package:grid_app/features/agents/logic/adapters/codex_tool.dart';
import 'package:grid_app/features/agents/logic/adapters/hermes_tool.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/features/agents/logic/agent_grid_support.dart';
import 'package:grid_app/features/agents/logic/auto_agent.dart';
import 'package:grid_app/features/agents/logic/auto_agent_router.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/playground/logic/playground_models.dart';
import 'package:grid_app/infrastructure/api/chat_transport.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

const _all = [AgentTool.hermes, AgentTool.codex, AgentTool.claude];

NetworkCredential _credential() => const NetworkCredential(
  networkId: 'net',
  name: 'Test grid',
  networkType: 'permissioned',
  lanSignalingUrl: 'https://grid.example/g1',
  accessToken: 'tok',
  refreshToken: '',
  email: '',
  nodeId: '',
  deviceId: '',
  roles: [],
  scopes: [],
  memberEpoch: 1,
  networkEpoch: 1,
  expiresAt: 0,
);

class _FixedNetwork extends SelectedNetwork {
  @override
  NetworkCredential? build() => _credential();
}

/// A transport that answers the classifier with one canned reply, or fails the
/// way an unreachable grid does.
class _FakeClassifier implements ChatTransport {
  _FakeClassifier({this.reply, this.error});

  final String? reply;
  final ChatTransportError? error;

  int calls = 0;
  String? lastEndpoint;
  String? lastModel;
  List<Map<String, dynamic>>? lastMessages;

  @override
  Stream<ChatStreamEvent> stream({
    String? turnId,
    required String endpoint,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    String? conversationId,
  }) async* {
    calls++;
    lastEndpoint = endpoint;
    lastModel = model;
    lastMessages = messages;
    if (error != null) {
      yield ChatFailed(error!);
      return;
    }
    if (reply != null) yield ChatDelta(reply!);
    yield const ChatDone();
  }
}

/// A grid that serves the `auto` router, with every agent installed and runnable
/// unless a test says otherwise — the shape the Auto agent is meant for.
ProviderContainer _routerContainer({
  required ChatTransport transport,
  bool servesAuto = true,
  Set<AgentTool> blocked = const {},
  Set<AgentTool> missing = const {},
}) {
  final container = ProviderContainer(
    overrides: [
      chatTransportProvider.overrideWithValue(transport),
      selectedNetworkProvider.overrideWith(_FixedNetwork.new),
      gridServesAutoModelProvider.overrideWith((ref) => servesAuto),
      hermesInstalledProvider.overrideWithValue(
        !missing.contains(AgentTool.hermes),
      ),
      codexInstalledProvider.overrideWithValue(
        !missing.contains(AgentTool.codex),
      ),
      claudeInstalledProvider.overrideWithValue(
        !missing.contains(AgentTool.claude),
      ),
      agentRunsOnGridProvider.overrideWith(
        (ref, tool) => !blocked.contains(tool),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

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

  group('asking the grid which agent should answer', () {
    test('the grid names one, and it is the one that answers', () async {
      final grid = _FakeClassifier(reply: 'codex');
      final container = _routerContainer(transport: grid);

      final picked = await container
          .read(autoAgentRouterProvider)
          .route(question: 'refactor this module', candidates: _all);

      expect(picked, AgentTool.codex);
      // The user's own words for this feature: the grid's own URL, and the auto
      // model, which is the router the grid runs for exactly this kind of pick.
      expect(
        grid.lastEndpoint,
        'https://grid.example/g1/relay/v1/chat/completions',
      );
      expect(grid.lastModel, 'auto');
      expect(grid.lastMessages?.last['content'], 'refactor this module');
    });

    test('one candidate is not worth a round trip', () async {
      // The only installed agent answers whatever the grid would have said, so
      // asking spends a relay call and seconds of the user's turn on nothing.
      final grid = _FakeClassifier(reply: 'codex');
      final container = _routerContainer(transport: grid);

      final picked = await container
          .read(autoAgentRouterProvider)
          .route(question: 'anything', candidates: const [AgentTool.hermes]);

      expect(picked, AgentTool.hermes);
      expect(grid.calls, 0);
    });

    test('an unreachable grid still answers, by keyword', () async {
      // Degrading to the heuristic is the whole design: a routing failure must
      // never become a chat that didn't reply.
      final container = _routerContainer(
        transport: _FakeClassifier(
          error: const ChatTransportError('connection refused'),
        ),
      );

      final picked = await container
          .read(autoAgentRouterProvider)
          .route(question: 'fix the bug in my code', candidates: _all);

      expect(picked, AgentTool.claude);
    });

    test('a reply naming nobody falls back rather than guessing', () async {
      final container = _routerContainer(
        transport: _FakeClassifier(reply: 'whichever you think is best'),
      );

      final picked = await container
          .read(autoAgentRouterProvider)
          .route(question: 'what is the capital of France?', candidates: _all);

      expect(picked, AgentTool.hermes);
    });

    test('a grid with no auto model is asked on a plain text model', () async {
      // `resolveOneShotTarget` fills in: any working text model can classify,
      // and asking a grid for `auto` when it serves none would be refused.
      final grid = _FakeClassifier(reply: 'hermes');
      final container = _routerContainer(transport: grid, servesAuto: false);

      await container
          .read(autoAgentRouterProvider)
          .route(question: 'hello', candidates: _all);

      expect(grid.lastModel, isNot('auto'));
    });

    test('no candidate at all resolves to the default agent, never throws', () {
      final container = _routerContainer(
        transport: _FakeClassifier(reply: 'codex'),
      );
      expect(
        container
            .read(autoAgentRouterProvider)
            .route(question: 'hello', candidates: const []),
        completion(kChatAgent),
      );
    });
  });

  group('who Auto is allowed to choose between', () {
    test('an agent that cannot answer with this turn\'s model is out', () {
      // A grid of `claude:*` seats has nothing to hand a Codex turn to, and the
      // composer's wall is computed for the agent *it* resolved — so without
      // this the turn dead-ends at the relay on a pair the user never picked.
      final container = _routerContainer(
        transport: _FakeClassifier(reply: 'codex'),
      );
      final pool = container.read(autoAgentCandidatesProvider('claude:opus'));
      expect(pool, isNot(contains(AgentTool.codex)));
      expect(pool, contains(AgentTool.claude));
    });

    test(
      'the auto model excludes nobody — every agent can be pointed at it',
      () {
        final container = _routerContainer(
          transport: _FakeClassifier(reply: 'codex'),
        );
        expect(container.read(autoAgentCandidatesProvider('auto')), _all);
      },
    );

    test('an agent this machine or this grid cannot run is out', () {
      final container = _routerContainer(
        transport: _FakeClassifier(reply: 'codex'),
        blocked: {AgentTool.codex},
      );
      expect(container.read(autoAgentCandidatesProvider('auto')), const [
        AgentTool.hermes,
        AgentTool.claude,
      ]);
    });

    test('when no agent suits the model, the runnable ones still stand', () {
      // Auto has nothing useful to say here, so it must not invent an emptier
      // failure than the one the composer already explains.
      final container = _routerContainer(
        transport: _FakeClassifier(reply: 'codex'),
        missing: {AgentTool.hermes, AgentTool.claude},
      );
      expect(container.read(autoAgentCandidatesProvider('claude:opus')), const [
        AgentTool.codex,
      ]);
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
