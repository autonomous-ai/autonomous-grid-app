import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/app_guide_snippets.dart';

const _base = 'https://grid.example/relay/v1';
const _key = 'sk-test-123';
const _model = 'qwen3.5:0.8b';

void main() {
  test('env snippet exports both OpenAI values', () {
    final out = envSnippet(_base, _key);
    expect(out, contains('OPENAI_BASE_URL="$_base"'));
    expect(out, contains('OPENAI_API_KEY="$_key"'));
  });

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
    expect(config, contains('provider: custom:Grid.autonomous.ai'));
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
}
