import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/playground/logic/playground_models.dart';
import 'package:grid_app/features/playground/logic/playground_request.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';

void main() {
  group('mediaModeOptions', () {
    test('offers an Image mode for a comfyui image provider', () {
      // The capabilities the real "autonomous" grid's comfyui node advertises.
      final options =
          mediaModeOptions(['comfyui:image_generation', 'comfyui:image_editing']);
      expect(options, hasLength(1));
      expect(options.single.modality, PlaygroundModality.image);
      expect(options.single.label, kImageModeLabel);
    });

    test('image editing alone still offers the Image mode', () {
      final options = mediaModeOptions(['comfyui:image_editing']);
      expect(options.single.modality, PlaygroundModality.image);
    });

    test('offers a Video mode for an i2v provider', () {
      final options = mediaModeOptions(['comfyui:i2v']);
      expect(options.single.modality, PlaygroundModality.video);
      expect(options.single.label, kVideoModeLabel);
    });

    test('offers both when the grid has image and video capabilities', () {
      final options = mediaModeOptions(
          ['comfyui:image_generation', 'comfyui:i2v']);
      expect(options.map((o) => o.modality).toList(),
          [PlaygroundModality.image, PlaygroundModality.video]);
    });

    test('a text-only grid offers no media modes', () {
      expect(mediaModeOptions(['deepreinforce-ai/ornith-1.0-35b']), isEmpty);
      expect(mediaModeOptions(const []), isEmpty);
    });
  });

  test('OverviewNode parses the capability list beside the primary model', () {
    final node = OverviewNode.fromJson(const {
      'name': 'engine-57d44159',
      'engine': 'comfyui',
      'model': 'comfyui:image_generation',
      'models': ['comfyui:image_generation', 'comfyui:image_editing'],
      'online': true,
    });
    expect(node.model, 'comfyui:image_generation');
    expect(node.models,
        ['comfyui:image_generation', 'comfyui:image_editing']);
  });
}
