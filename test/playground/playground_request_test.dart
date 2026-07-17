import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/playground/logic/playground_request.dart';

void main() {
  group('modalityFromString', () {
    test('maps image/video, defaults everything else to text', () {
      expect(modalityFromString('image'), PlaygroundModality.image);
      expect(modalityFromString('video'), PlaygroundModality.video);
      expect(modalityFromString('chat'), PlaygroundModality.text);
      expect(modalityFromString('text'), PlaygroundModality.text);
      expect(modalityFromString(null), PlaygroundModality.text);
      expect(modalityFromString('nonsense'), PlaygroundModality.text);
    });

    test('is case-insensitive and trims', () {
      expect(modalityFromString(' Image '), PlaygroundModality.image);
      expect(modalityFromString('VIDEO'), PlaygroundModality.video);
    });
  });

  group('MediaOperation', () {
    test('paths and capabilities match the relay contract', () {
      expect(MediaOperation.imageGenerate.path, 'media/image/generate');
      expect(
        MediaOperation.imageGenerate.capability,
        'comfyui:image_generation',
      );
      expect(MediaOperation.imageEdit.path, 'media/image/edit');
      expect(MediaOperation.imageEdit.capability, 'comfyui:image_editing');
      expect(MediaOperation.i2v.path, 'media/video/i2v');
      expect(MediaOperation.i2v.capability, 'comfyui:i2v');
    });
  });

  group('payloads', () {
    test(
      'imageGeneratePayload carries capability, prompt and 1024² defaults',
      () {
        final payload = imageGeneratePayload('a mug');
        expect(payload['capability'], 'comfyui:image_generation');
        expect(payload['prompt'], 'a mug');
        expect(payload['width'], 1024);
        expect(payload['height'], 1024);
        expect(payload['steps'], 4);
      },
    );

    test(
      'imageEditPayload encodes each source image as {filename, content_base64}',
      () {
        final img = MediaAttachment(
          filename: 'in.png',
          bytes: Uint8List.fromList([1, 2, 3]),
        );
        final payload = imageEditPayload('brighten it', [img]);
        expect(payload['capability'], 'comfyui:image_editing');
        final images = payload['input_images'] as List;
        expect(images, hasLength(1));
        expect(images.first, {
          'filename': 'in.png',
          'content_base64': base64.encode([1, 2, 3]),
        });
      },
    );

    test('i2vPayload attaches a single input image plus motion defaults', () {
      final img = MediaAttachment(
        filename: 'seed.jpg',
        bytes: Uint8List.fromList([9, 9]),
      );
      final payload = i2vPayload('pan slowly', img);
      expect(payload['capability'], 'comfyui:i2v');
      expect(payload['prompt'], 'pan slowly');
      expect(payload['duration'], '5s');
      expect(payload['aspect_ratio'], '2:3');
      expect((payload['input_image'] as Map)['filename'], 'seed.jpg');
    });
  });
}
