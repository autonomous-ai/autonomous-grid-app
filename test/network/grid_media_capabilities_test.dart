import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/grid_overview_provider.dart';

void main() {
  group('gridMediaCapabilitiesFrom', () {
    test('image generation or editing counts as image', () {
      expect(gridMediaCapabilitiesFrom(['comfyui:image_generation']).image, isTrue);
      expect(gridMediaCapabilitiesFrom(['comfyui:image_editing']).image, isTrue);
    });

    test('i2v counts as video', () {
      final caps = gridMediaCapabilitiesFrom(['comfyui:i2v']);
      expect(caps.video, isTrue);
      expect(caps.image, isFalse);
    });

    test('the real autonomous grid node advertises image, not video', () {
      final caps = gridMediaCapabilitiesFrom(
          ['comfyui:image_generation', 'comfyui:image_editing']);
      expect(caps.image, isTrue);
      expect(caps.video, isFalse);
      expect(caps.any, isTrue);
    });

    test('a text-only grid has no media capabilities', () {
      final caps = gridMediaCapabilitiesFrom(['deepreinforce-ai/ornith-1.0-35b']);
      expect(caps.any, isFalse);
    });
  });
}
