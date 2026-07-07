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

  group('playgroundOptionsFrom', () {
    test('hides raw comfyui:* models, keeps text models + the coded Image mode',
        () {
      // Mirrors the "Art" grid: the relay leaks the comfyui capabilities into
      // the model list. They can't be tested directly, so only the coded Image
      // mode should be selectable alongside real text models.
      final options = playgroundOptionsFrom(
        const [
          OverviewModel(id: 'comfyui:image_generation'),
          OverviewModel(id: 'comfyui:image_editing'),
          OverviewModel(id: 'qwen3-coder'),
        ],
        const ['comfyui:image_generation', 'comfyui:image_editing'],
      );
      final ids = options.map((o) => o.id).toList();
      expect(ids, isNot(contains('comfyui:image_generation')));
      expect(ids, isNot(contains('comfyui:image_editing')));
      expect(ids, ['qwen3-coder', kImageModeLabel]);
    });

    test('a media-only grid offers just the coded mode, no comfyui:i2v row', () {
      // Mirrors the "Hollywood" grid: only i2v. The picker should show the coded
      // Video mode alone.
      final options = playgroundOptionsFrom(
        const [OverviewModel(id: 'comfyui:i2v')],
        const ['comfyui:i2v'],
      );
      expect(options.map((o) => o.id).toList(), [kVideoModeLabel]);
      expect(options.single.modality, PlaygroundModality.video);
    });

    test('passes plain text models straight through', () {
      final options = playgroundOptionsFrom(
        const [OverviewModel(id: 'a'), OverviewModel(id: 'b')],
        const [],
      );
      expect(options.map((o) => o.id).toList(), ['a', 'b']);
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
