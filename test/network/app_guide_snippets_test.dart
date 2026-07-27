import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/app_guide_snippets.dart';
import 'package:grid_app/features/network/logic/client_app_detector.dart';
import 'package:toml/toml.dart';

const _base = 'https://grid.example/relay/v1';
const _key = 'sk-test-123';
const _model = 'qwen3.5:0.8b';

void main() {
  test('OpenClaw snippet is valid JSON wiring Grid as a merged provider', () {
    final decoded = jsonDecode(openClawSnippet(_base, _key, [_model])) as Map;
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

  test('OpenClaw snippet lists every grid model, first as the default', () {
    const ids = ['a-model', 'b-model', 'c-model'];
    final decoded = jsonDecode(openClawSnippet(_base, _key, ids)) as Map;
    final grid =
        ((decoded['models'] as Map)['providers'] as Map)['grid'] as Map;
    final listed = (grid['models'] as List)
        .map((m) => (m as Map)['id'])
        .toList();
    expect(listed, ids); // all three, in order
    expect(decoded['agents']['defaults']['model']['primary'], 'grid/a-model');
  });

  test('OpenClaw snippet falls back to the default id for an empty grid', () {
    final decoded = jsonDecode(openClawSnippet(_base, _key, const [])) as Map;
    final grid =
        ((decoded['models'] as Map)['providers'] as Map)['grid'] as Map;
    expect((grid['models'] as List).single['id'], kGuideDefaultModel);
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

  test('Hermes config speaks the Responses dialect for a codex model', () {
    const codexModel = 'codex:gpt-5.5';
    final config = hermesConfigSnippet(_base, _key, codexModel);
    // A responses-only model must select a NAMED provider — a bare `custom` is
    // silently downgraded to chat-completions on a non-OpenAI host — and carry
    // the api_mode that switches Hermes onto POST /responses.
    expect(config, contains('provider: $kHermesGridProviderKey\n'));
    expect(config, isNot(contains('provider: custom')));
    expect(config, contains('provider_key: $kHermesGridProviderKey'));
    expect(config, contains('api_mode: $kHermesResponsesApiMode'));
    expect(config, contains('default: $codexModel'));
  });

  group('Codex', () {
    test('config block is valid TOML selecting the grid provider', () {
      final toml = TomlDocument.parse(
        codexConfigSnippet(_base, _model),
      ).toMap();
      expect(toml['model'], _model);
      expect(toml['model_provider'], kCodexProviderId);
      final grid = (toml['model_providers'] as Map)[kCodexProviderId] as Map;
      expect(grid['base_url'], _base);
      // Codex ≥ 0.141 rejects `wire_api = "chat"` outright, so the provider must
      // stay on the Responses API.
      expect(grid['wire_api'], 'responses');
      // Codex has no api_key field — it reads the key from this env var, so the
      // key must never leak into config.toml.
      expect(grid['env_key'], gridApiKeyEnv);
      expect(codexConfigSnippet(_base, _model), isNot(contains(_key)));
    });

    test('env block carries the key Codex loads from its dotenv', () {
      expect(codexEnvSnippet(_key), '$gridApiKeyEnv=$_key');
    });

    test('appSnippets gives Codex both files: config then key', () {
      final blocks = appSnippets(
        kClientApps[ClientApp.codex]!,
        _base,
        _key,
        const [_model],
      );
      expect(blocks.length, 2);
      expect(blocks.first.caption, contains('~/.codex/config.toml'));
      expect(
        blocks.first.code,
        contains('[model_providers.$kCodexProviderId]'),
      );
      expect(blocks.last.caption, contains(kCodexEnvPath));
      expect(blocks.last.code, contains(_key));
    });

    test('appSnippets gives the file-based clients a single block', () {
      for (final app in [ClientApp.openClaw, ClientApp.hermes]) {
        final blocks = appSnippets(kClientApps[app]!, _base, _key, const [
          _model,
        ]);
        expect(blocks.single.code, contains(_base));
      }
    });

    test('appSnippets falls back to the default model for an empty grid', () {
      final blocks = appSnippets(
        kClientApps[ClientApp.codex]!,
        _base,
        _key,
        const [],
      );
      expect(blocks.first.code, contains('model = "$kGuideDefaultModel"'));
    });
  });

  group('Buzz', () {
    test('global config is valid JSON with the openai-compat pair', () {
      final decoded =
          jsonDecode(buzzGlobalConfigSnippet(_base, _key, _model)) as Map;
      // The desktop translates this provider to BUZZ_AGENT_PROVIDER=openai; a
      // free-text value kills the agent at startup.
      expect(decoded['provider'], kBuzzProvider);
      expect(decoded['model'], _model);
      final env = decoded['env_vars'] as Map;
      // Must be the OPENAI_COMPAT_* names — the bare OPENAI_* ones fail with
      // "OPENAI_COMPAT_API_KEY required".
      expect(env[kBuzzBaseUrlEnv], _base);
      expect(env[kBuzzApiKeyEnv], _key);
      // A plain chat model speaks chat-completions, not the Responses API.
      expect(env[kBuzzApiModeEnv], 'chat');
    });

    test('a codex model switches Buzz onto the Responses API', () {
      final decoded =
          jsonDecode(buzzGlobalConfigSnippet(_base, _key, 'codex:gpt-5.5'))
              as Map;
      expect((decoded['env_vars'] as Map)[kBuzzApiModeEnv], 'responses');
    });

    test('appSnippets gives Buzz a single block naming its config file', () {
      final blocks = appSnippets(kClientApps[ClientApp.buzz]!, _base, _key, [
        _model,
      ]);
      expect(blocks.single.caption, contains('global-agent-config.json'));
      expect(blocks.single.code, contains('"$kBuzzProvider"'));
      expect(blocks.single.code, contains(_base));
    });
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

    test(
      'image + video grid includes both calls and the chain-to-video note',
      () {
        final out = mediaSkillPrompt(_base, _key, image: true, video: true);
        expect(out, contains('media/image/generate'));
        expect(out, contains('media/video/i2v'));
        expect(out, contains('images and videos'));
        expect(out, contains('first call the image/generate endpoint above'));
      },
    );
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
