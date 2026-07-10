import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/codex_agent/logic/codex_chat_sender.dart';
import 'package:grid_app/features/codex_agent/logic/codex_exec_args.dart';
import 'package:grid_app/features/codex_agent/logic/codex_providers.dart';
import 'package:grid_app/infrastructure/cli/codex_agent_service.dart';
import 'package:grid_app/infrastructure/cli/codex_event.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';
import 'package:grid_app/features/playground/logic/chat_sender.dart';
import 'package:grid_app/features/playground/logic/playground_request.dart';
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

/// A [CodexAgentService] that replays scripted events and records the spawn.
class _FakeCodexService implements CodexAgentService {
  _FakeCodexService(this._events, {int exit = 0}) : _exit = exit;
  final List<CodexEvent> _events;
  final int _exit;
  List<String>? args;
  Map<String, String>? env;
  String? workdir;

  @override
  CodexRun exec({
    required List<String> args,
    required Map<String, String> environment,
    required String workdir,
  }) {
    this.args = args;
    env = environment;
    this.workdir = workdir;
    return CodexRun(
      events: Stream.fromIterable(_events),
      exitCode: Future.value(_exit),
      kill: () {},
    );
  }
}

ProviderContainer _container(
  CodexAgentService? service, {
  Directory? workspace,
}) {
  final container = ProviderContainer(
    overrides: [
      codexAgentServiceProvider.overrideWithValue(service),
      if (workspace != null)
        agentWorkspaceDirProvider.overrideWithValue(workspace),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

List<ChatMessage> _history(String text) => [
  ChatMessage(role: ChatRole.user, text: text),
];

void main() {
  test('a completed agent_message becomes the assistant reply', () async {
    final service = _FakeCodexService([
      const CodexTurnStarted(),
      const CodexAgentMessage('the answer is 42'),
      const CodexTurnCompleted(),
    ]);
    final container = _container(service, workspace: Directory('/tmp/ws'));

    final updates = await container
        .read(codexChatSenderProvider)
        .send(
          network: _credential(),
          model: 'qwen/qwen3.6-27b',
          history: _history('what is the answer'),
        )
        .toList();

    expect(updates.last, isA<ChatSendSuccess>());
    expect((updates.last as ChatSendSuccess).reply.text, 'the answer is 42');
    // The key rode in the environment, not argv.
    expect(service.env![gridApiKeyEnv], 'secret-token');
    expect(service.workdir, '/tmp/ws');
  });

  test(
    'a 404 turn failure is humanized to a backend-pending message',
    () async {
      final service = _FakeCodexService([
        const CodexStreamError('Reconnecting... 1/5'),
        const CodexTurnFailed(
          'unexpected status 404 Not Found, url: .../relay/v1/responses',
        ),
      ], exit: 1);
      final container = _container(service, workspace: Directory('/tmp/ws'));

      final updates = await container
          .read(codexChatSenderProvider)
          .send(
            network: _credential(),
            model: 'qwen/qwen3.6-27b',
            history: _history('hi'),
          )
          .toList();

      expect(updates.last, isA<ChatSendFailure>());
      expect((updates.last as ChatSendFailure).error, contains('backend'));
    },
  );

  test('no codex installed reports a friendly install line', () async {
    final container = _container(null, workspace: Directory('/tmp/ws'));

    final updates = await container
        .read(codexChatSenderProvider)
        .send(
          network: _credential(),
          model: 'qwen/qwen3.6-27b',
          history: _history('hi'),
        )
        .toList();

    expect(updates.single, isA<ChatSendFailure>());
    expect((updates.single as ChatSendFailure).error, contains('Codex'));
  });

  test(
    'activity steps are recorded, a started step collapsing into done',
    () async {
      final service = _FakeCodexService([
        const CodexActivityUpdate(
          CodexActivity(
            id: 'i2',
            kind: CodexActivityKind.command,
            label: 'ls',
            status: CodexActivityStatus.running,
          ),
        ),
        const CodexActivityUpdate(
          CodexActivity(
            id: 'i2',
            kind: CodexActivityKind.command,
            label: 'ls',
            status: CodexActivityStatus.done,
          ),
        ),
        const CodexAgentMessage('done'),
      ]);
      final container = _container(service, workspace: Directory('/tmp/ws'));

      await container
          .read(codexChatSenderProvider)
          .send(
            network: _credential(),
            model: 'qwen/qwen3.6-27b',
            history: _history('go'),
          )
          .toList();

      final steps = container.read(codexActivityProvider);
      expect(steps, hasLength(1));
      expect(steps.single.status, CodexActivityStatus.done);
    },
  );

  test('non-text modality is rejected', () async {
    final service = _FakeCodexService(const []);
    final container = _container(service, workspace: Directory('/tmp/ws'));

    final updates = await container
        .read(codexChatSenderProvider)
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
