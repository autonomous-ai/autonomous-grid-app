import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/app_guide_snippets.dart';

const _base = 'https://grid.example/relay/v1';
const _key = 'sk-test-123';
const _model = 'qwen3.5:0.8b';

void main() {
  test('OpenClaw snippet is valid JSON wiring Grid as a merged provider', () {
    final decoded = jsonDecode(openClawSnippet(_base, _key, _model)) as Map;
    final models = decoded['models'] as Map;
    // merge appends Grid to OpenClaw's built-ins instead of replacing them.
    expect(models['mode'], 'merge');
    final grid = (models['providers'] as Map)['grid'] as Map;
    expect(grid['baseUrl'], _base);
    expect(grid['apiKey'], _key);
    expect(grid['api'], 'openai-completions');
    expect((grid['models'] as List).first['id'], _model);
    expect(decoded['agents']['defaults']['model']['primary'], 'grid/$_model');
  });

  test('Hermes config block carries the full grid connection', () {
    final config = hermesConfigSnippet(_base, _key, _model);
    // Must be the bare `custom` provider — Hermes reads base_url/api_key straight
    // from the model block. A `custom:<host>` value is rejected as an unknown
    // provider ("agent init failed"), so pin the exact line (trailing newline
    // guards against a `custom:...` regression slipping past a substring match).
    expect(config, contains('provider: custom\n'));
    expect(config, contains('base_url: $_base'));
    expect(config, contains('api_key: $_key'));
    expect(config, contains('default: $_model'));
    expect(config, contains('max_tokens: $kHermesMaxTokens'));
    // Also registers the grid as a named custom provider.
    expect(config, contains('custom_providers:'));
    expect(config, contains('name: ${hermesProviderName(_base)}'));
    expect(config, contains('model: $_model'));
  });

  test('Python snippet points the SDK at the pair', () {
    final out = pythonSnippet(_base, _key, _model);
    expect(out, contains('base_url="$_base"'));
    expect(out, contains('api_key="$_key"'));
    expect(out, contains('model="$_model"'));
  });

  group('media skill prompt', () {
    test('image grid carries the generate endpoint + connection, no i2v', () {
      final out = mediaSkillPrompt(_base, _key, image: true, video: false);
      expect(out, contains('Base URL: $_base'));
      expect(out, contains('API key: $_key'));
      expect(out, contains('POST $_base/media/image/generate'));
      expect(out, contains('"capability":"comfyui:image_generation"'));
      expect(out, contains('images'));
      // No model name — the relay routes media by capability.
      expect(out, contains("Don't send a model name"));
      // Lessons folded in from the real working Hermes skill (docs/hermes-skill.md):
      // curl over urllib, timestamped filenames, show the result inline.
      expect(out, contains('CERTIFICATE_VERIFY_FAILED'));
      expect(out, contains('curl'));
      expect(out, contains('timestamped'));
      expect(out, contains('show me the result'));
      expect(out, isNot(contains('media/video/i2v')));
    });

    test('video grid carries i2v + the "you need not see the image" rule', () {
      final out = mediaSkillPrompt(_base, _key, image: false, video: true);
      expect(out, contains('POST $_base/media/video/i2v'));
      expect(out, contains('"capability":"comfyui:i2v"'));
      expect(out, contains('videos'));
      // The agent must not try to visually read the source image — that's what
      // broke the first skill. It only base64-encodes the bytes.
      expect(out, contains('NOT need to open, view, or understand the image'));
      expect(out, contains("Never stop with \"I can't see the image\""));
      expect(out, isNot(contains('media/image/generate')));
      // No chaining note when the grid can't generate a starting image.
      expect(out, isNot(contains('first call the image/generate')));
    });

    test('image + video grid includes both calls and the chain-to-video note', () {
      final out = mediaSkillPrompt(_base, _key, image: true, video: true);
      expect(out, contains('media/image/generate'));
      expect(out, contains('media/video/i2v'));
      expect(out, contains('images and videos'));
      expect(out, contains('first call the image/generate endpoint above'));
    });
  });

  group('media API curl', () {
    test('image grid emits a generate curl only', () {
      final out = mediaApiCurl(_base, _key, image: true, video: false);
      expect(out, contains('curl -N $_base/media/image/generate'));
      expect(out, contains('Authorization: Bearer $_key'));
      expect(out, contains('Accept: text/event-stream'));
      expect(out, contains('"capability":"comfyui:image_generation"'));
      expect(out, isNot(contains('media/video/i2v')));
    });

    test('video grid emits an i2v curl only', () {
      final out = mediaApiCurl(_base, _key, image: false, video: true);
      expect(out, contains('curl -N $_base/media/video/i2v'));
      expect(out, contains('"capability":"comfyui:i2v"'));
      expect(out, isNot(contains('media/image/generate')));
    });
  });
}
