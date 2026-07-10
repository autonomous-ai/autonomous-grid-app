import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/codex_agent/logic/codex_providers.dart';
import 'package:grid_app/features/codex_agent/logic/hermes_chat_sender.dart';
import 'package:grid_app/features/network/logic/client_app_configurator.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';
import 'package:grid_app/features/playground/logic/chat_sender.dart';
import 'package:grid_app/features/playground/logic/playground_request.dart';
import 'package:grid_app/infrastructure/cli/codex_event.dart';
import 'package:grid_app/infrastructure/cli/hermes_acp_service.dart';
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

/// A [HermesAcpService] that replays scripted ACP events and records the prompt.
class _FakeAcp implements HermesAcpService {
  _FakeAcp(this._events);
  final List<HermesAcpEvent> _events;
  String? text;

  @override
  HermesAcpRun prompt({required String text, required String workdir}) {
    this.text = text;
    return HermesAcpRun(
      events: Stream.fromIterable(_events),
      done: Future.value(),
      kill: () {},
    );
  }
}

ProviderContainer _container(HermesAcpService? service, Directory tmp) {
  final container = ProviderContainer(
    overrides: [
      hermesAcpServiceProvider.overrideWithValue(service),
      agentWorkspaceDirProvider.overrideWithValue(Directory('${tmp.path}/ws')),
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

CodexActivity _step(String id, CodexActivityStatus status) => CodexActivity(
  id: id,
  kind: CodexActivityKind.command,
  label: 'terminal: ls',
  status: status,
);

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_hermes_test');
  });
  tearDown(() => tmp.delete(recursive: true));

  test('streams tool activity and joins the answer chunks', () async {
    final service = _FakeAcp([
      HermesAcpActivity(_step('tc1', CodexActivityStatus.running)),
      HermesAcpActivity(_step('tc1', CodexActivityStatus.done)),
      const HermesAcpMessage('PANGO'),
      const HermesAcpMessage('LIN'),
    ]);
    final container = _container(service, tmp);

    final updates = await container
        .read(hermesChatSenderProvider)
        .send(
          network: _credential(),
          model: 'qwen/qwen3.6-27b',
          history: _history('read notes'),
        )
        .toList();

    expect(updates.last, isA<ChatSendSuccess>());
    expect((updates.last as ChatSendSuccess).reply.text, 'PANGOLIN');
    // The activity feed collapsed the started→done tool into one done step.
    final steps = container.read(codexActivityProvider);
    expect(steps, hasLength(1));
    expect(steps.single.status, CodexActivityStatus.done);
    // Pointed Hermes at the grid.
    expect(File('${tmp.path}/.hermes/config.yaml').existsSync(), isTrue);
  });

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

  test('a turn with no answer text is a failure', () async {
    final service = _FakeAcp([
      HermesAcpActivity(_step('tc1', CodexActivityStatus.done)),
    ]);
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
    final service = _FakeAcp(const []);
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
    expect(service.text, isNull);
  });
}
