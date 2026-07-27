import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/chat_row_status.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';

void main() {
  group('chatActivityFor', () {
    test('an idle chat has no activity to show on its row', () {
      expect(chatActivityFor(const SendIdle()), isNull);
    });

    test('a request in flight before any answer reads as thinking — the agent '
        'working or the reply not started yet', () {
      expect(chatActivityFor(const SendBusy()), ChatActivity.thinking);
    });

    test('a streaming reply reads as typing', () {
      expect(
        chatActivityFor(const SendStreaming('half an answer')),
        ChatActivity.typing,
      );
      // Still typing before the first token lands.
      expect(chatActivityFor(const SendStreaming('')), ChatActivity.typing);
    });

    test('a media generation reads as creating', () {
      expect(
        chatActivityFor(const SendGenerating(progress: 0.4, status: 'running')),
        ChatActivity.creating,
      );
    });
  });
}
