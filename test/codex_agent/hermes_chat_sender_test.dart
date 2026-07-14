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

/// A [HermesAcpService] whose sessions replay a scripted turn's events and
/// record every prompt, so a test can assert on session reuse and on the exact
/// text each turn sent. [_turns] is a list of turns; each turn is the events to
/// replay for that `prompt` call.
class _FakeAcp implements HermesAcpService {
  _FakeAcp(this._turns);

  /// One-turn convenience matching the common case.
  _FakeAcp.single(List<HermesAcpEvent> events) : _turns = [events];

  final List<List<HermesAcpEvent>> _turns;
  final sessions = <_FakeAcpSession>[];

  int get startCount => sessions.length;

  /// Every prompt across every session, in order — the text each turn sent.
  List<String> get prompts => [for (final s in sessions) ...s.prompts];

  @override
  Future<HermesAcpSession> start({required String workdir}) async {
    final session = _FakeAcpSession(_turns);
    sessions.add(session);
    return session;
  }
}

class _FakeAcpSession implements HermesAcpSession {
  _FakeAcpSession(this._turns);

  final List<List<HermesAcpEvent>> _turns;
  final prompts = <String>[];
  int _turn = 0;
  bool _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  HermesAcpRun prompt(String text) {
    prompts.add(text);
    final events = _turn < _turns.length ? _turns[_turn] : const <HermesAcpEvent>[];
    _turn++;
    return HermesAcpRun(
      events: Stream.fromIterable(events),
      done: Future.value(),
      kill: () {},
    );
  }

  @override
  Future<void> close() async => _closed = true;
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

  test('streams the answer as it arrives, then joins the chunks', () async {
    final service = _FakeAcp.single([
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

    // The answer streams in cumulatively before the terminal success.
    final streamed = updates.whereType<ChatSendStreaming>().toList();
    expect(streamed.map((u) => u.text), ['PANGO', 'PANGOLIN']);
    expect(updates.last, isA<ChatSendSuccess>());
    expect((updates.last as ChatSendSuccess).reply.text, 'PANGOLIN');
    // The activity feed collapsed the started→done tool into one done step.
    final steps = container.read(codexActivityProvider);
    expect(steps, hasLength(1));
    expect(steps.single.status, CodexActivityStatus.done);
    // Pointed Hermes at the grid.
    expect(File('${tmp.path}/.hermes/config.yaml').existsSync(), isTrue);
  });

  test('one live session per conversation — later turns send only the new '
      'message', () async {
    final service = _FakeAcp([
      [const HermesAcpMessage('hi there')],
      [const HermesAcpMessage('sure thing')],
    ]);
    final container = _container(service, tmp);
    final sender = container.read(hermesChatSenderProvider);

    await sender
        .send(
          network: _credential(),
          model: 'm',
          conversationId: 'conv-1',
          history: const [ChatMessage(role: ChatRole.user, text: 'hello')],
        )
        .toList();

    // Second turn of the same conversation: history carries the whole thread.
    await sender
        .send(
          network: _credential(),
          model: 'm',
          conversationId: 'conv-1',
          history: const [
            ChatMessage(role: ChatRole.user, text: 'hello'),
            ChatMessage(role: ChatRole.assistant, text: 'hi there'),
            ChatMessage(role: ChatRole.user, text: 'thanks'),
          ],
        )
        .toList();

    // The process was spawned once and reused.
    expect(service.startCount, 1);
    // First turn seeded context; the second sent only the new user turn, not
    // the whole history re-flattened.
    expect(service.prompts, ['hello', 'thanks']);
  });

  test('switching conversation starts a fresh session', () async {
    final service = _FakeAcp([
      [const HermesAcpMessage('a')],
      [const HermesAcpMessage('b')],
    ]);
    final container = _container(service, tmp);
    final sender = container.read(hermesChatSenderProvider);

    await sender
        .send(
          network: _credential(),
          model: 'm',
          conversationId: 'conv-1',
          history: _history('one'),
        )
        .toList();
    await sender
        .send(
          network: _credential(),
          model: 'm',
          conversationId: 'conv-2',
          history: _history('two'),
        )
        .toList();

    expect(service.startCount, 2);
    expect(service.sessions.first.isClosed, isTrue, reason: 'old one closed');
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
    final service = _FakeAcp.single([
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
    final service = _FakeAcp.single(const []);
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
    expect(service.startCount, 0);
  });
}
