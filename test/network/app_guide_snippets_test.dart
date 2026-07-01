import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/app_guide_snippets.dart';

const _base = 'https://grid.example/relay/v1';
const _key = 'sk-test-123';

void main() {
  test('env snippet exports both OpenAI values', () {
    final out = envSnippet(_base, _key);
    expect(out, contains('OPENAI_BASE_URL="$_base"'));
    expect(out, contains('OPENAI_API_KEY="$_key"'));
  });

  test('OpenClaw snippet is valid JSON wiring Grid as a merged provider', () {
    final decoded = jsonDecode(openClawSnippet(_base, _key)) as Map;
    final models = decoded['models'] as Map;
    // merge appends Grid to OpenClaw's built-ins instead of replacing them.
    expect(models['mode'], 'merge');
    final grid = (models['providers'] as Map)['grid'] as Map;
    expect(grid['baseUrl'], _base);
    expect(grid['apiKey'], _key);
    expect(grid['api'], 'openai-completions');
  });

  test('Hermes snippets carry the base into config and key into env', () {
    final config = hermesConfigSnippet(_base);
    expect(config, contains('provider: custom'));
    expect(config, contains('model: $kGuideDefaultModel'));
    expect(config, contains('base_url: $_base'));
    expect(hermesEnvSnippet(_key), contains('OPENAI_API_KEY=$_key'));
  });

  test('Python snippet points the SDK at the pair', () {
    final out = pythonSnippet(_base, _key);
    expect(out, contains('base_url="$_base"'));
    expect(out, contains('api_key="$_key"'));
    expect(out, contains('model="$kGuideDefaultModel"'));
  });
}
