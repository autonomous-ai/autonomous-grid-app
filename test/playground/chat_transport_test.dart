import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/api/chat_transport.dart';

/// The relay streams `chat/completions` as OpenAI-style SSE. These pin the pure
/// parsing — which chunks add text and which are skipped — and the fallback for
/// a relay that ignores `stream` and sends one JSON body, so a slow answer fills
/// the bubble token by token without a live relay in the loop.
void main() {
  group('chatStreamDelta — one SSE chunk', () {
    test('pulls the text out of choices[0].delta.content', () {
      expect(
        chatStreamDelta('{"choices":[{"delta":{"content":"Hel"}}]}'),
        'Hel',
      );
    });

    test('a role-only opener adds nothing', () {
      // The first chunk announces the assistant role with no content — it must
      // not write an empty string into the reply.
      expect(
        chatStreamDelta('{"choices":[{"delta":{"role":"assistant"}}]}'),
        isNull,
      );
    });

    test('a finish chunk carries no content', () {
      expect(
        chatStreamDelta('{"choices":[{"delta":{},"finish_reason":"stop"}]}'),
        isNull,
      );
    });

    test('a malformed chunk is skipped, not fatal', () {
      // A heartbeat or a truncated line must not abort the whole answer.
      expect(chatStreamDelta('not json'), isNull);
      expect(chatStreamDelta('{"choices":[]}'), isNull);
      expect(chatStreamDelta('{}'), isNull);
    });

    test('an empty content delta is empty, not null — the caller drops it', () {
      expect(chatStreamDelta('{"choices":[{"delta":{"content":""}}]}'), '');
    });
  });

  group('chatStreamWholeBody — a relay that ignored stream', () {
    test('reads a plain completion body the old non-streaming way', () {
      const body =
          '{"choices":[{"message":{"role":"assistant","content":"Hello there"}}]}';
      expect(chatStreamWholeBody(body), 'Hello there');
    });

    test('an empty or non-completion body yields nothing', () {
      expect(chatStreamWholeBody(''), '');
      expect(chatStreamWholeBody('   '), '');
      expect(chatStreamWholeBody('not json'), '');
      expect(chatStreamWholeBody('{"unexpected":true}'), '');
    });
  });

  group('ChatTransportComplete.complete — draining the stream', () {
    test('folds every delta into one reply for a one-shot caller', () async {
      final (reply, error) = await _ScriptedTransport([
        const ChatDelta('Hel'),
        const ChatDelta('lo'),
        const ChatDone(),
      ]).complete(endpoint: 'x', apiKey: '', model: 'm', messages: const []);

      expect(reply, 'Hello');
      expect(error, isNull);
    });

    test('a failure ends the drain with the error, no partial reply', () async {
      final (reply, error) = await _ScriptedTransport([
        const ChatDelta('Hel'),
        const ChatFailed(ChatTransportError('boom', statusCode: 500)),
      ]).complete(endpoint: 'x', apiKey: '', model: 'm', messages: const []);

      expect(reply, isNull);
      expect(error?.message, 'boom');
    });
  });
}

/// Yields a fixed sequence of events, so [ChatTransportComplete.complete] is
/// tested without a socket.
class _ScriptedTransport implements ChatTransport {
  _ScriptedTransport(this.events);
  final List<ChatStreamEvent> events;

  @override
  Stream<ChatStreamEvent> stream({
    String? turnId,
    required String endpoint,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    String? conversationId,
  }) async* {
    for (final event in events) {
      yield event;
    }
  }
}
