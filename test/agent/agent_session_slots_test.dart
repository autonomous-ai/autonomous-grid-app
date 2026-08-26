import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_providers.dart';
import 'package:grid_app/features/agents/logic/agent_session_slots.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';

List<ChatMessage> _history(int turns) => [
  for (var i = 0; i < turns; i++)
    ChatMessage(
      role: i.isEven ? ChatRole.user : ChatRole.assistant,
      text: 'message $i',
    ),
];

/// Run one turn end to end: plan it, then record what the agent reported back —
/// the session id it opened, and the answer it appended.
AgentTurnPlan _answered(
  AgentSessionSlots slots, {
  required String key,
  required String? conversationId,
  required List<ChatMessage> history,
  String sessionId = 'sess-1',
}) {
  final turn = slots.planTurn(
    key: key,
    conversationId: conversationId,
    history: history,
  );
  turn.slot.sessionId = sessionId;
  turn.slot.seen++;
  return turn;
}

void main() {
  group('a conversation the agent is already holding', () {
    test('the second turn sends only what the agent has not seen, and resumes '
        'its session rather than replaying the chat at it', () {
      final slots = AgentSessionSlots();
      final first = _answered(
        slots,
        key: 'grid|model|c1|/work',
        conversationId: 'c1',
        history: _history(1),
      );
      expect(first.freshStart, isTrue);
      expect(first.resumeSessionId, isNull);

      final second = slots.planTurn(
        key: 'grid|model|c1|/work',
        conversationId: 'c1',
        history: _history(3),
      );
      expect(second.resumeSessionId, 'sess-1');
      expect(second.freshStart, isFalse);
      // The first turn plus the answer it produced are the agent's own; only
      // what came after goes down the wire.
      expect(second.text, contains('message 2'));
      expect(second.text, isNot(contains('message 0')));
    });

    test(
      'a turn the agent never answered leaves nothing to resume — its id was '
      'never learned, so the next one starts over',
      () {
        final slots = AgentSessionSlots();
        slots.planTurn(
          key: 'grid|model|c1|/work',
          conversationId: 'c1',
          history: _history(1),
        );
        final next = slots.planTurn(
          key: 'grid|model|c1|/work',
          conversationId: 'c1',
          history: _history(3),
        );
        expect(next.resumeSessionId, isNull);
        expect(next.freshStart, isTrue);
        expect(next.text, contains('message 0'));
      },
    );
  });

  group('what counts as a different session', () {
    test('a different model, grid or project folder starts fresh — the agent '
        'holding the old one would answer from the wrong place', () {
      for (final key in [
        'grid|other-model|c1|/work',
        'other-grid|model|c1|/work',
        'grid|model|c1|/other',
      ]) {
        final slots = AgentSessionSlots();
        _answered(
          slots,
          key: 'grid|model|c1|/work',
          conversationId: 'c1',
          history: _history(1),
        );
        final next = slots.planTurn(
          key: key,
          conversationId: 'c1',
          history: _history(3),
        );
        expect(next.freshStart, isTrue, reason: key);
        expect(next.resumeSessionId, isNull, reason: key);
      }
    });

    test('another conversation gets its own slot, and the first keeps its '
        'session', () {
      final slots = AgentSessionSlots();
      _answered(
        slots,
        key: 'grid|model|c1|/work',
        conversationId: 'c1',
        history: _history(1),
      );
      _answered(
        slots,
        key: 'grid|model|c2|/work',
        conversationId: 'c2',
        history: _history(1),
        sessionId: 'sess-2',
      );

      final back = slots.planTurn(
        key: 'grid|model|c1|/work',
        conversationId: 'c1',
        history: _history(3),
      );
      expect(back.resumeSessionId, 'sess-1');
    });
  });

  test('past the cap the least recently used conversation is forgotten, which '
      'costs it a replay and nothing else', () {
    final slots = AgentSessionSlots();
    for (var i = 0; i <= kMaxLiveAgentSessions; i++) {
      _answered(
        slots,
        key: 'grid|model|c$i|/work',
        conversationId: 'c$i',
        history: _history(1),
        sessionId: 'sess-$i',
      );
    }

    // c0 was the first in and never touched again.
    final evicted = slots.planTurn(
      key: 'grid|model|c0|/work',
      conversationId: 'c0',
      history: _history(3),
    );
    expect(evicted.freshStart, isTrue);
    // The most recent one is still held.
    final kept = slots.planTurn(
      key: 'grid|model|c$kMaxLiveAgentSessions|/work',
      conversationId: 'c$kMaxLiveAgentSessions',
      history: _history(3),
    );
    expect(kept.resumeSessionId, 'sess-$kMaxLiveAgentSessions');
  });
}
