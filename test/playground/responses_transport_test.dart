import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';
import 'package:grid_app/features/playground/logic/message_media.dart';
import 'package:grid_app/features/playground/logic/responses_transport.dart';

void main() {
  group('buildResponsesInput', () {
    test('types user text as input_text and assistant text as output_text', () {
      final input = buildResponsesInput(const [
        ChatMessage(role: ChatRole.user, text: 'hello'),
        ChatMessage(role: ChatRole.assistant, text: 'hi there'),
        ChatMessage(role: ChatRole.user, text: 'thanks'),
      ], (_) => null);

      expect(input, [
        {
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': 'hello'},
          ],
        },
        {
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': 'hi there'},
          ],
        },
        {
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': 'thanks'},
          ],
        },
      ]);
    });

    test('skips empty turns and drops unreadable images', () {
      final input = buildResponsesInput(
        const [
          ChatMessage(role: ChatRole.user, text: ''),
          ChatMessage(
            role: ChatRole.user,
            text: 'look',
            media: [ChatMedia(path: '/gone.png', kind: MediaKind.image)],
          ),
        ],
        (_) => null, // image file can't be read → dropped
      );

      expect(input, [
        {
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': 'look'},
          ],
        },
      ]);
    });

    test('carries a readable user image as an input_image data URI', () {
      final input = buildResponsesInput(const [
        ChatMessage(
          role: ChatRole.user,
          text: 'what is this',
          media: [ChatMedia(path: '/a.png', kind: MediaKind.image)],
        ),
      ], (_) => 'data:image/png;base64,AAAA');

      expect(input.single['content'], [
        {'type': 'input_text', 'text': 'what is this'},
        {'type': 'input_image', 'image_url': 'data:image/png;base64,AAAA'},
      ]);
    });
  });

  group('extractResponsesText', () {
    test('concatenates output_text parts and ignores non-message items', () {
      final text = HttpResponsesTransport.extractResponsesText({
        'output': [
          {
            'type': 'reasoning',
            'content': [
              {'type': 'reasoning_text', 'text': 'thinking...'},
            ],
          },
          {
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': 'Hello, '},
              {'type': 'output_text', 'text': 'world.'},
            ],
          },
        ],
      });

      expect(text, 'Hello, world.');
    });

    test('returns empty string for shapes it cannot read', () {
      expect(HttpResponsesTransport.extractResponsesText(null), '');
      expect(HttpResponsesTransport.extractResponsesText('nope'), '');
      expect(HttpResponsesTransport.extractResponsesText({'output': 42}), '');
    });
  });
}
