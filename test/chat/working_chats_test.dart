import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/chat_sessions_controller.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/chat/logic/working_chats.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';
import 'package:grid_app/features/playground/logic/playground_request.dart';

final _t0 = DateTime.utc(2026, 8, 17, 9);

Conversation _chat(String id, {String? projectId}) => Conversation(
  id: id,
  title: 'Chat $id',
  model: 'qwen',
  createdAt: _t0,
  updatedAt: _t0,
  projectId: projectId,
);

QueuedTurn _queued() => const QueuedTurn(
  network: NetworkCredential(
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
  ),
  model: 'qwen',
  text: 'and after that?',
  modality: PlaygroundModality.text,
  attachments: [],
);

void main() {
  test('only the chats actually answering are listed — an idle chat in the '
      'history is not something the user has to stop', () {
    final state = ChatSessionsState(
      conversations: [_chat('a'), _chat('b')],
      phases: const {'a': SendBusy()},
      turnStartedAt: {'a': _t0},
    );

    expect(buildWorkingChats(state).rows.map((r) => r.id), ['a']);
  });

  test('the longest-running turn leads, because that is the one the user has '
      'lost track of', () {
    final state = ChatSessionsState(
      // Newest-first in the sidebar, so the list order alone would put the
      // youngest turn on top.
      conversations: [_chat('young'), _chat('old')],
      phases: const {'young': SendBusy(), 'old': SendBusy()},
      turnStartedAt: {
        'young': _t0.add(const Duration(minutes: 20)),
        'old': _t0,
      },
    );

    expect(buildWorkingChats(state).rows.map((r) => r.id), ['old', 'young']);
  });

  test('a turn dispatched a moment ago, before its clock was set, sorts last '
      'rather than first — it is the youngest thing here', () {
    final state = ChatSessionsState(
      conversations: [_chat('unclocked'), _chat('running')],
      phases: const {'unclocked': SendBusy(), 'running': SendBusy()},
      turnStartedAt: {'running': _t0},
    );

    expect(buildWorkingChats(state).rows.map((r) => r.id), [
      'running',
      'unclocked',
    ]);
  });

  test('a row carries who is answering, where, and what is waiting behind it — '
      'the three things the panel says under the chat\'s name', () {
    final state = ChatSessionsState(
      conversations: [_chat('a', projectId: 'proj')],
      phases: const {'a': SendStreaming('half an answer')},
      runningAgents: const {'a': 'codex'},
      turnStartedAt: {'a': _t0},
      queued: {
        'a': [_queued(), _queued()],
      },
    );

    final row = buildWorkingChats(state).rows.single;
    expect(row.agentId, 'codex');
    expect(row.projectId, 'proj');
    expect(row.queued, 2);
    expect(row.startedAt, _t0);
  });

  test('a turn the grid itself is answering has no agent to name — a picture, '
      'or a computer with no agent installed', () {
    final state = ChatSessionsState(
      conversations: [_chat('a')],
      phases: const {'a': SendBusy()},
      turnStartedAt: {'a': _t0},
    );

    expect(buildWorkingChats(state).rows.single.agentId, isNull);
  });

  test('a streamed token leaves the list equal to itself, so the top bar and '
      'the palette are not rebuilt on every word of a reply', () {
    ChatSessionsState streaming(String text) => ChatSessionsState(
      conversations: [_chat('a')],
      phases: {'a': SendStreaming(text)},
      runningAgents: const {'a': 'hermes'},
      turnStartedAt: {'a': _t0},
    );

    expect(
      buildWorkingChats(streaming('Half')),
      buildWorkingChats(streaming('Half an answer')),
    );
  });

  test('a chat starting or stopping does change the list — the one moment the '
      'watchers must hear about', () {
    final one = ChatSessionsState(
      conversations: [_chat('a'), _chat('b')],
      phases: const {'a': SendBusy()},
      turnStartedAt: {'a': _t0},
    );
    final two = ChatSessionsState(
      conversations: [_chat('a'), _chat('b')],
      phases: const {'a': SendBusy(), 'b': SendBusy()},
      turnStartedAt: {'a': _t0, 'b': _t0},
    );

    expect(buildWorkingChats(one), isNot(buildWorkingChats(two)));
    expect(buildWorkingChats(two).ids, {'a', 'b'});
  });
}
