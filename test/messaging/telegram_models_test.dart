import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/features/auth/logic/session_controller.dart';
import 'package:grid_app/features/messaging/logic/telegram/telegram_models.dart';
import 'package:grid_app/features/network/logic/grid_overview_provider.dart';
import 'package:grid_app/features/network/logic/network_models_provider.dart';
import 'package:grid_app/features/playground/logic/playground_models.dart';
import 'package:grid_app/features/playground/logic/playground_request.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';
import 'package:grid_app/features/playground/logic/grid_served_models.dart';

PlaygroundModelOption _option(
  String id, {
  String? label,
  PlaygroundModality modality = PlaygroundModality.text,
}) => PlaygroundModelOption(id: id, label: label ?? id, modality: modality);

NetworkCredential _grid() => NetworkCredential(
  networkId: 'grid-1',
  name: 'grid-1',
  networkType: 'permissioned',
  lanSignalingUrl: 'http://127.0.0.1:8090',
  accessToken: 'tok',
  refreshToken: '',
  email: 'dev@x.com',
  nodeId: 'node',
  deviceId: 'dev',
  roles: const ['consumer'],
  scopes: const ['consumer:chat'],
  memberEpoch: 1,
  networkEpoch: 1,
  expiresAt: 0,
);

/// The bot reads the grid's models from a Notifier of its own, outside any
/// build — the shape [gridServedModels] actually runs in.
final _botProvider = NotifierProvider<_Bot, int>(_Bot.new);

class _Bot extends Notifier<int> {
  @override
  int build() => 0;

  Future<List<PlaygroundModelOption>> models() => gridServedModels(ref);
}

/// A container where the grid answers `/models` after [delay] — the request in
/// flight that a cold read never waits for.
ProviderContainer _container({
  List<String> served = const ['llama', 'qwen'],
  Duration delay = const Duration(milliseconds: 20),
}) {
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWithValue(
        CredentialsFile(networks: [_grid()], activeNetwork: 'grid-1'),
      ),
      networkModelsForProvider.overrideWith((ref, id) async {
        await Future<void>.delayed(delay);
        return served;
      }),
      gridOverviewForProvider.overrideWith(
        (ref, id) async => GridOverview.fromJson(const {
          'grid': {'state': 'active'},
          'stats': {'models': 0, 'nodes': 0},
          'models': [],
          'nodes': [],
        }),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('the models a phone is offered', () {
    test('are waited for, so /model lists what the grid serves even with '
        'nobody watching the Chat tab', () async {
      final container = _container();

      // What the menu used to offer: the empty list the provider starts from,
      // thrown away with the request that would have filled it.
      expect(container.read(playgroundModelsProvider), isEmpty);

      final models = await container.read(_botProvider.notifier).models();

      expect([for (final option in models) option.id], ['llama', 'qwen']);
    });

    test('come back for the command after it too — the listener that held the '
        'list is closed, not the list', () async {
      final bot = _container(
        served: const ['llama'],
      ).read(_botProvider.notifier);

      expect(await bot.models(), isNotEmpty);
      expect(await bot.models(), isNotEmpty);
    });

    test('are empty rather than wrong when the grid never answers', () async {
      final container = ProviderContainer(
        overrides: [
          sessionProvider.overrideWithValue(
            const CredentialsFile(networks: []),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(await container.read(_botProvider.notifier).models(), isEmpty);
    });
  });

  group('the rows /model offers', () {
    test('leave out what the assistant answering cannot take, so no row '
        'dead-ends at the relay minutes after it was tapped', () {
      final rows = telegramModelItems(
        options: [_option('llama'), _option('codex:gpt-5.5')],
        agent: AgentTool.claude,
        current: 'llama',
      );

      expect([for (final row in rows) row.value], ['llama']);
    });

    test('leave out the image and video modes, which no message can use', () {
      final rows = telegramModelItems(
        options: [
          _option('llama'),
          _option('flux', modality: PlaygroundModality.image),
        ],
        agent: AgentTool.hermes,
        current: '',
      );

      expect([for (final row in rows) row.value], ['llama']);
    });

    test('tick the one in use, so the menu says where the chat stands', () {
      final rows = telegramModelItems(
        options: [
          _option('llama', label: 'Llama'),
          _option('qwen'),
        ],
        agent: AgentTool.hermes,
        current: 'llama',
      );

      expect(rows.first.label, 'Llama ✓');
      expect(rows.last.label, 'qwen');
    });
  });

  group('/model with a name typed after it', () {
    final rows = [
      (label: 'DeepSeek-V4', value: 'DeepSeek-V4'),
      (label: 'llama', value: 'llama'),
    ];

    test('answers with the id the grid serves, never the casing that was '
        'typed — the relay matches ids exactly', () {
      expect(telegramModelNamed(rows, ' deepseek-v4 '), 'DeepSeek-V4');
    });

    test('is null for a model this grid is not serving, so the bot says so '
        'instead of sending a turn nobody can answer', () {
      expect(telegramModelNamed(rows, 'gpt-5'), isNull);
      expect(telegramModelNamed(rows, '  '), isNull);
    });
  });
}
