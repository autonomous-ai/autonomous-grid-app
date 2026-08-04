import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/claude_chat_sender.dart';
import 'package:grid_app/features/agent/logic/model_context_window.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/network/logic/grid_overview_provider.dart';
import 'package:grid_app/features/network/logic/network_models_provider.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';
import 'package:grid_app/infrastructure/state/model_context_store.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

/// The turn that started this: Claude Code relaying what the office engine said
/// when it refused a conversation 2k tokens too long for it.
const _refusal =
    'API Error: 400 request (98013 tokens) exceeds the available context size '
    '(96000 tokens), try increasing it';

/// The same refusal in vLLM's wording, which a grid can just as easily be
/// serving — the number is the model's, not the request's, in both.
const _vllmRefusal =
    "This model's maximum context length is 96000 tokens. However, you "
    'requested 98013 tokens.';

NetworkCredential _network(String id) => NetworkCredential(
  networkId: id,
  name: id,
  networkType: 'permissioned',
  lanSignalingUrl: 'http://127.0.0.1:8090',
  accessToken: 'tok-$id',
  refreshToken: '',
  email: 'dev@x.com',
  nodeId: 'node-$id',
  deviceId: 'dev',
  roles: const ['consumer'],
  scopes: const ['consumer:chat'],
  memberEpoch: 1,
  networkEpoch: 1,
  expiresAt: 0,
);

void main() {
  group('contextWindowFromError', () {
    test('reads the window out of the refusal, since it is the only place any '
        'engine ever names it', () {
      expect(contextWindowFromError(_refusal), 96000);
      expect(contextWindowFromError(_vllmRefusal), 96000);
    });

    test(
      'llama.cpp names no number, so nothing is learned rather than guessed',
      () {
        const raw =
            'the request exceeds the available context size. try increasing the '
            'context size or enable context shift';
        expect(isContextOverflow(raw), isTrue);
        expect(contextWindowFromError(raw), isNull);
      },
    );

    test(
      'an unrelated failure teaches nothing and is not mistaken for one',
      () {
        const raw = 'API Error: 404 {"detail":"Not Found"}';
        expect(isContextOverflow(raw), isFalse);
        expect(contextWindowFromError(raw), isNull);
      },
    );
  });

  group('agentContextCeiling', () {
    test('leaves the engine room for the reply, which counts against the same '
        'window', () {
      expect(agentContextCeiling(96000), 76800);
      // The failure this exists to prevent overshot by 2k; the headroom has to
      // absorb that and an answer on top of it.
      expect(96000 - agentContextCeiling(96000), greaterThan(2013));
    });
  });

  test('the chat is told what to do rather than shown a 400', () {
    expect(friendlyClaudeError(_refusal), kClaudeContextFull);
  });

  group('LearnedModelContext', () {
    ProviderContainer containerOn(File file) {
      final container = ProviderContainer(
        overrides: [
          modelContextStoreProvider.overrideWithValue(
            ModelContextStore(file: file),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('what one dead turn taught survives the app being closed', () async {
      final dir = await Directory.systemTemp.createTemp('grid-ctx');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/model_context.json');

      containerOn(file)
          .read(learnedModelContextProvider.notifier)
          .learn('qwen3.6-27b-office', 96000);

      // A second app start, reading the same file.
      final reopened = containerOn(file);
      expect(
        reopened
            .read(learnedModelContextProvider.notifier)
            .windowFor('Qwen3.6-27B-Office'),
        96000,
      );
    });

    test('a window of zero is refused: it would stop every turn before it '
        'started', () async {
      final dir = await Directory.systemTemp.createTemp('grid-ctx');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/model_context.json');
      await file.writeAsString('{"m": 0, "n": "nonsense"}');

      final container = containerOn(file);
      expect(container.read(learnedModelContextProvider), isEmpty);
      container.read(learnedModelContextProvider.notifier).learn('m', 0);
      expect(container.read(learnedModelContextProvider), isEmpty);
    });
  });

  group('modelContextWindowProvider', () {
    /// A grid serving one model, advertising [advertised] for it (null being
    /// what every grid says today), with [learned] already in the store.
    Future<ProviderContainer> gridServing({
      int? advertised,
      Map<String, int> learned = const {},
    }) async {
      final container = ProviderContainer(
        overrides: [
          selectedNetworkProvider.overrideWith(
            () => _FixedSelectedNetwork(_network('grid-foo')),
          ),
          // Never touched while the overview has models of its own, but the app
          // reads it in the moment before that lands — and a test must not go
          // near a real relay.
          networkModelsForProvider(
            'grid-foo',
          ).overrideWith((ref) => Future.value(const <String>[])),
          gridOverviewForProvider('grid-foo').overrideWith(
            (ref) => Future.value(
              GridOverview(
                stats: const GridStats(models: 1, nodes: 0),
                models: [
                  OverviewModel(
                    id: 'qwen3.6-27b-office',
                    contextLength: advertised,
                  ),
                ],
                nodes: const [],
              ),
            ),
          ),
          modelContextStoreProvider.overrideWithValue(_StubStore(learned)),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(gridOverviewProvider, (_, _) {});
      addTearDown(sub.close);
      await pumpEventQueue();
      return container;
    }

    test('takes the smaller of what the grid advertises and what an engine '
        'taught: one model id can be served by machines that differ', () async {
      final roomier = await gridServing(
        advertised: 128000,
        learned: {'qwen3.6-27b-office': 96000},
      );
      expect(
        roomier.read(modelContextWindowProvider('qwen3.6-27b-office')),
        96000,
      );

      final tighter = await gridServing(
        advertised: 32768,
        learned: {'qwen3.6-27b-office': 96000},
      );
      expect(
        tighter.read(modelContextWindowProvider('qwen3.6-27b-office')),
        32768,
      );
    });

    test('a grid that advertises nothing — every grid, today — still runs on '
        'what its engine taught', () async {
      final container = await gridServing(
        learned: {'qwen3.6-27b-office': 96000},
      );
      expect(
        container.read(modelContextWindowProvider('qwen3.6-27b-office')),
        96000,
      );
    });

    test("a model nothing is known about gets no ceiling: Claude Code's own "
        'default beats a made-up number', () async {
      final container = await gridServing();
      expect(
        container.read(modelContextWindowProvider('qwen3.6-27b-office')),
        isNull,
      );
    });
  });
}

/// A store backed by a fixed map, so a test can start with lessons already
/// learned without going near a file.
class _StubStore implements ModelContextStore {
  const _StubStore(this._windows);
  final Map<String, int> _windows;

  @override
  Map<String, int> load() => _windows;

  @override
  void save(Map<String, int> windows) {}
}

/// A [SelectedNetwork] pinned to a fixed grid, so the overview-backed providers
/// resolve without the session/prefs wiring the real notifier reads from disk.
class _FixedSelectedNetwork extends SelectedNetwork {
  _FixedSelectedNetwork(this._fixed);
  final NetworkCredential? _fixed;
  @override
  NetworkCredential? build() => _fixed;
}
