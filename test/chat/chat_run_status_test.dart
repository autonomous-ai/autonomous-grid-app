import 'package:flutter_test/flutter_test.dart';

import 'package:grid_app/features/agents/logic/agent_run_status.dart';
import 'package:grid_app/features/chat/logic/chat_sessions_state.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';

final _t0 = DateTime.utc(2026, 8, 17, 9);

Conversation _chat(String id) => Conversation(
  id: id,
  title: 'Chat $id',
  model: 'qwen',
  createdAt: _t0,
  updatedAt: _t0,
);

ChatSessionsState _state({
  Map<String, SendPhase> phases = const {},
  Map<String, String?> errors = const {},
  Set<String> awaitingPlan = const {},
  Map<String, String> runningAgents = const {},
}) => ChatSessionsState(
  conversations: [_chat('a'), _chat('b')],
  phases: phases,
  errors: errors,
  awaitingPlanIds: awaitingPlan,
  runningAgents: runningAgents,
);

void main() {
  test('an idle chat is nothing — a row at rest wears no status dot', () {
    expect(chatRunState(_state(), 'a'), isNull);
  });

  test('a send in flight reads as running, the green dot', () {
    expect(
      chatRunState(_state(phases: const {'a': SendBusy()}), 'a'),
      AgentRunState.running,
    );
  });

  test('a chat whose agent is running even while its phase is idle reads as '
      'running, so a background turn still shows', () {
    expect(
      chatRunState(_state(runningAgents: const {'a': 'codex'}), 'a'),
      AgentRunState.running,
    );
  });

  test('a plan waiting on the user reads as waiting, the blue dot', () {
    expect(
      chatRunState(_state(awaitingPlan: const {'a'}), 'a'),
      AgentRunState.waiting,
    );
  });

  test('a turn that errored reads as failed, the red dot', () {
    expect(
      chatRunState(_state(errors: const {'a': 'something broke'}), 'a'),
      AgentRunState.failed,
    );
  });

  test('a failure beats a still-listed run — the most urgent state is the one '
      'the dot shows', () {
    expect(
      chatRunState(
        _state(errors: const {'a': 'boom'}, phases: const {'a': SendBusy()}),
        'a',
      ),
      AgentRunState.failed,
    );
  });

  test('one chat in error is read on its own — a healthy neighbour stays '
      'idle', () {
    final state = _state(errors: const {'a': 'boom'});
    expect(chatRunState(state, 'a'), AgentRunState.failed);
    expect(chatRunState(state, 'b'), isNull);
  });
}
