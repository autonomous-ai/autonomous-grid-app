import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/adapters/pi_chat_sender.dart';
import 'package:grid_app/features/agents/logic/agent_providers.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';
import 'package:grid_app/features/playground/logic/chat_sender.dart';
import 'package:grid_app/infrastructure/cli/pi_exec_service.dart';
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

/// A [PiExecService] that replays one scripted turn per `run` call and records
/// what each turn was asked to do — the two facts a session's continuity rests
/// on: which session it resumed, and what it had to say to catch the agent up.
class _FakePi implements PiExecService {
  _FakePi(this._turns);

  final List<List<PiExecEvent>> _turns;
  final calls = <({String? resumeSessionId, String prompt})>[];

  @override
  PiExecRun run({
    required String workdir,
    required String prompt,
    required String model,
    required Map<String, String> environment,
    String? resumeSessionId,
  }) {
    calls.add((resumeSessionId: resumeSessionId, prompt: prompt));
    final events = _turns.removeAt(0);
    final controller = StreamController<PiExecEvent>();
    final done = Completer<void>();
    scheduleMicrotask(() async {
      for (final event in events) {
        controller.add(event);
      }
      done.complete();
      await controller.close();
    });
    return PiExecRun(events: controller.stream, done: done.future, kill: () {});
  }
}

ProviderContainer _container(_FakePi pi, Directory tmp) {
  final container = ProviderContainer(
    overrides: [
      piExecServiceProvider.overrideWithValue(pi),
      // Never the real `~/.grid`: a test that files sessions in the user's home
      // is a test that changes the machine it runs on.
      piSessionDirProvider.overrideWithValue(Directory('${tmp.path}/sessions')),
      agentWorkspaceDirProvider.overrideWithValue(Directory('${tmp.path}/ws')),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<List<ChatSendUpdate>> _send(
  ProviderContainer container,
  Directory tmp,
  List<ChatMessage> history,
) => container
    .read(piChatSenderProvider)
    .send(
      network: _credential(),
      model: 'qwen3',
      history: history,
      workdir: tmp.path,
      conversationId: 'chat-1',
    )
    .toList();

ChatMessage _user(String text) => ChatMessage(role: ChatRole.user, text: text);

ChatMessage _assistant(String text) =>
    ChatMessage(role: ChatRole.assistant, text: text);

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pi-sender-');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('a turn that answers reports the answer, and the next one resumes the '
      'session instead of replaying the chat', () async {
    final pi = _FakePi([
      [
        const PiSessionStarted('sess-1'),
        const PiMessageEvent('Here you go.'),
        const PiTurnCompleted(),
      ],
      [const PiMessageEvent('And again.'), const PiTurnCompleted()],
    ]);
    final container = _container(pi, tmp);

    final first = await _send(container, tmp, [_user('hello')]);
    expect((first.last as ChatSendSuccess).reply.text, 'Here you go.');

    await _send(container, tmp, [
      _user('hello'),
      _assistant('Here you go.'),
      _user('more'),
    ]);
    expect(pi.calls.map((c) => c.resumeSessionId), [null, 'sess-1']);
    // Only the new message goes with a resumed turn — pi's own session holds
    // the rest.
    expect(pi.calls.last.prompt, contains('more'));
    expect(pi.calls.last.prompt, isNot(contains('hello')));
  });

  test('a failure the agent settled on reaches the chat as a failure, not as a '
      'half-written answer', () async {
    final pi = _FakePi([
      [const PiTurnFailed('HTTP 503: no providers')],
    ]);
    final container = _container(pi, tmp);

    final updates = await _send(container, tmp, [_user('hello')]);
    expect(updates.last, isA<ChatSendFailure>());
  });

  test(
    'a session pi can no longer find ends that chat once, not every time: '
    'the slot is dropped so the next send starts over with the history',
    () async {
      final pi = _FakePi([
        [
          const PiSessionStarted('sess-1'),
          const PiMessageEvent('Here you go.'),
          const PiTurnCompleted(),
        ],
        [const PiTurnFailed("No session found matching 'sess-1'")],
        [const PiMessageEvent('Back.'), const PiTurnCompleted()],
      ]);
      final container = _container(pi, tmp);

      await _send(container, tmp, [_user('hello')]);
      final lost = await _send(container, tmp, [
        _user('hello'),
        _assistant('Here you go.'),
        _user('more'),
      ]);
      // Said in the user's terms, with the one thing that fixes it.
      expect(
        (lost.last as ChatSendFailure).error,
        'Pi lost track of this conversation. Send your message again to start '
        'it over.',
      );

      final recovered = await _send(container, tmp, [
        _user('hello'),
        _assistant('Here you go.'),
        _user('more'),
      ]);
      expect((recovered.last as ChatSendSuccess).reply.text, 'Back.');
      // A fresh session, and the whole conversation replayed into it.
      expect(pi.calls.last.resumeSessionId, isNull);
      expect(pi.calls.last.prompt, contains('hello'));
      expect(pi.calls.last.prompt, contains('more'));
    },
  );
}
