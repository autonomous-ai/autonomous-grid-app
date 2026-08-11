import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/adapters/pi_grid_config.dart';

void main() {
  group('piModelsJson — the grid as an OpenAI-compatible provider', () {
    test('names the grid base, the openai-completions API, and an env-ref key '
        '(never the secret itself)', () {
      final decoded =
          jsonDecode(piModelsJson(base: 'https://x/relay/v1', model: 'qwen3'))
              as Map<String, dynamic>;
      final grid = (decoded['providers'] as Map)['grid'] as Map;
      expect(grid['baseUrl'], 'https://x/relay/v1');
      expect(grid['api'], 'openai-completions');
      // An env reference resolved at request time — no key is written to disk.
      expect(grid['apiKey'], '\$$kPiAppApiKeyEnv');
      final model = (grid['models'] as List).single as Map;
      expect(model['id'], 'qwen3');
      expect(model['name'], 'qwen3');
    });
  });

  group('piSettingsJson — the run config dir', () {
    test("passes the user's own skills through, so a turn in an app-owned "
        'config dir still loads what the Skills screen manages', () {
      final decoded =
          jsonDecode(piSettingsJson(userSkillsDir: '/home/.pi/agent/skills'))
              as Map<String, dynamic>;
      expect(decoded['skills'], ['/home/.pi/agent/skills']);
    });

    test('says nothing about project trust — that is the run flag\'s job, and '
        'two places to set it is two places to disagree', () {
      final decoded =
          jsonDecode(piSettingsJson(userSkillsDir: '/home/.pi/agent/skills'))
              as Map<String, dynamic>;
      expect(decoded.containsKey('defaultProjectTrust'), isFalse);
    });

    test('omits skills when there is no user folder to pass through', () {
      final decoded = jsonDecode(piSettingsJson()) as Map<String, dynamic>;
      expect(decoded.containsKey('skills'), isFalse);
    });
  });

  group('piGridEnvironment — the child process env', () {
    test(
      'points pi at the run config and session dirs and hands over the key',
      () {
        final env = piGridEnvironment(
          configDir: '/tmp/cfg',
          sessionDir: '/home/.grid/app/pi/sessions',
          apiKey: 'sk-grid-123',
        );
        expect(env['PI_CODING_AGENT_DIR'], '/tmp/cfg');
        expect(
          env['PI_CODING_AGENT_SESSION_DIR'],
          '/home/.grid/app/pi/sessions',
        );
        expect(env[kPiAppApiKeyEnv], 'sk-grid-123');
        // An app-driven turn makes no startup network calls.
        expect(env['PI_OFFLINE'], '1');
      },
    );
  });
}
