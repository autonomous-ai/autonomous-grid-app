import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/codex_agent/logic/codex_providers.dart';
import 'package:grid_app/features/codex_agent/logic/hermes_chat_sender.dart';
import 'package:grid_app/features/network/logic/client_app_configurator.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';
import 'package:grid_app/features/playground/logic/chat_sender.dart';
import 'package:grid_app/features/playground/logic/playground_request.dart';
import 'package:grid_app/infrastructure/cli/hermes_agent_service.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';

NetworkCredential _credential() => const NetworkCredential(
  networkId: 'grid-1',
  name: 'Test grid',
  networkType: 'permissioned-providers',
  lanSignalingUrl: 'https://grid.example/grid-1',
  accessToken: 'secret-token',
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

/// A [HermesAgentService] that replays scripted stdout lines and records args.
class _FakeHermes implements HermesAgentService {
  _FakeHermes(this._lines, {int exit = 0}) : _exit = exit;
  final List<String> _lines;
  final int _exit;
  List<String>? args;

  @override
  HermesRun run({
    required List<String> args,
    required Map<String, String> environment,
    required String workdir,
  }) {
    this.args = args;
    return HermesRun(
      lines: Stream.fromIterable(_lines),
      exitCode: Future.value(_exit),
      kill: () {},
    );
  }
}

ProviderContainer _container(HermesAgentService? service, Directory tmp) {
  final container = ProviderContainer(
    overrides: [
      hermesAgentServiceProvider.overrideWithValue(service),
      agentWorkspaceDirProvider.overrideWithValue(Directory('${tmp.path}/ws')),
      // Real configurator pointed at a temp home so it never touches ~/.hermes.
      clientAppConfiguratorProvider.overrideWithValue(
        ClientAppConfigurator(home: tmp.path),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

List<ChatMessage> _history(String text) => [
  ChatMessage(role: ChatRole.user, text: text),
];

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_hermes_test');
  });
  tearDown(() => tmp.delete(recursive: true));

  test(
    'stdout lines become the assistant reply and point Hermes at the grid',
    () async {
      final service = _FakeHermes(['Hôm nay là', 'Thứ Tư.']);
      final container = _container(service, tmp);

      final updates = await container
          .read(hermesChatSenderProvider)
          .send(
            network: _credential(),
            model: 'qwen/qwen3.6-27b',
            history: _history('hôm nay thứ mấy'),
          )
          .toList();

      expect(updates.last, isA<ChatSendSuccess>());
      expect(
        (updates.last as ChatSendSuccess).reply.text,
        'Hôm nay là\nThứ Tư.',
      );
      expect(service.args, containsAllInOrder(['-z']));
      expect(service.args, containsAllInOrder(['-m', 'qwen/qwen3.6-27b']));
      expect(service.args, contains('--safe-mode'));
      // The grid endpoint was written into the temp Hermes config.
      expect(File('${tmp.path}/.hermes/config.yaml').existsSync(), isTrue);
    },
  );

  test('no hermes installed reports a friendly install line', () async {
    final container = _container(null, tmp);

    final updates = await container
        .read(hermesChatSenderProvider)
        .send(
          network: _credential(),
          model: 'qwen/qwen3.6-27b',
          history: _history('hi'),
        )
        .toList();

    expect(updates.single, isA<ChatSendFailure>());
    expect((updates.single as ChatSendFailure).error, contains('Hermes'));
  });

  test('empty output with a non-zero exit is a failure', () async {
    final service = _FakeHermes(const [], exit: 1);
    final container = _container(service, tmp);

    final updates = await container
        .read(hermesChatSenderProvider)
        .send(
          network: _credential(),
          model: 'qwen/qwen3.6-27b',
          history: _history('hi'),
        )
        .toList();

    expect(updates.last, isA<ChatSendFailure>());
  });

  test('non-text modality is rejected before spawning', () async {
    final service = _FakeHermes(const []);
    final container = _container(service, tmp);

    final updates = await container
        .read(hermesChatSenderProvider)
        .send(
          network: _credential(),
          model: 'qwen/qwen3.6-27b',
          history: _history('draw a cat'),
          modality: PlaygroundModality.image,
        )
        .toList();

    expect(updates.single, isA<ChatSendFailure>());
    expect(service.args, isNull);
  });
}
