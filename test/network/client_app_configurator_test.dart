import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/app_guide_snippets.dart';
import 'package:grid_app/features/network/logic/client_app_configurator.dart';
import 'package:grid_app/features/network/logic/client_app_detector.dart';

const _base = 'https://grid.example/relay/v1';
const _key = 'sk-test-123';

void main() {
  late Directory home;
  late ClientAppConfigurator sut;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('grid_cfg_test');
    sut = ClientAppConfigurator(home: home.path);
  });

  tearDown(() async {
    if (await home.exists()) await home.delete(recursive: true);
  });

  Map<String, dynamic> readJson(String rel) =>
      jsonDecode(File('${home.path}/$rel').readAsStringSync())
          as Map<String, dynamic>;

  group('OpenClaw', () {
    test('creates config with the Grid provider and a default model', () async {
      final result = await sut.apply(ClientApp.openClaw, _base, _key);

      expect(result, isA<ApplyOk>());
      expect((result as ApplyOk).note, isNull);
      final json = readJson('.openclaw/openclaw.json');
      expect(json['models']['mode'], 'merge');
      final grid = (json['models']['providers'] as Map)['grid'] as Map;
      expect(grid['baseUrl'], _base);
      expect(grid['apiKey'], _key);
      expect(json['agents']['defaults']['model']['primary'],
          'grid/$kGuideDefaultModel');
    });

    test('merges without clobbering other providers or the chosen model',
        () async {
      final file = File('${home.path}/.openclaw/openclaw.json');
      await file.create(recursive: true);
      await file.writeAsString(jsonEncode({
        'agents': {
          'defaults': {
            'model': {'primary': 'mine'}
          }
        },
        'models': {
          'providers': {
            'foo': {'baseUrl': 'x'}
          }
        },
      }));

      final result = await sut.apply(ClientApp.openClaw, _base, _key);

      expect((result as ApplyOk).note, isNotNull); // model kept ⇒ follow-up note
      final json = readJson('.openclaw/openclaw.json');
      final providers = json['models']['providers'] as Map;
      expect(providers.containsKey('foo'), isTrue);
      expect((providers['grid'] as Map)['baseUrl'], _base);
      expect(json['agents']['defaults']['model']['primary'], 'mine');
      expect(File('${file.path}.bak').existsSync(), isTrue);
    });

    test('reports an error for a corrupt config instead of throwing', () async {
      final file = File('${home.path}/.openclaw/openclaw.json');
      await file.create(recursive: true);
      await file.writeAsString('not json at all');

      final result = await sut.apply(ClientApp.openClaw, _base, _key);
      expect(result, isA<ApplyError>());
    });
  });

  group('Hermes', () {
    test('writes the key to .env and creates a fresh config.yaml', () async {
      final result = await sut.apply(ClientApp.hermes, _base, _key);

      expect(result, isA<ApplyOk>());
      final env = File('${home.path}/.hermes/.env').readAsStringSync();
      expect(env, contains('OPENAI_API_KEY=$_key'));
      expect(env, contains('OPENAI_BASE_URL=$_base'));
      final config = File('${home.path}/.hermes/config.yaml').readAsStringSync();
      expect(config, contains('base_url: $_base'));
    });

    test('leaves an existing config.yaml untouched and flags a follow-up',
        () async {
      final config = File('${home.path}/.hermes/config.yaml');
      await config.create(recursive: true);
      await config.writeAsString('model:\n  default: keep-me\n');

      final result = await sut.apply(ClientApp.hermes, _base, _key);

      expect((result as ApplyOk).note, isNotNull);
      expect(config.readAsStringSync(), 'model:\n  default: keep-me\n');
    });

    test('.env upsert replaces the key without duplicating others', () async {
      final env = File('${home.path}/.hermes/.env');
      await env.create(recursive: true);
      await env.writeAsString('OTHER=x\nOPENAI_API_KEY=old\n');

      await sut.apply(ClientApp.hermes, _base, _key);

      final lines = env
          .readAsStringSync()
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      expect(lines.where((l) => l.startsWith('OPENAI_API_KEY=')).length, 1);
      expect(lines, contains('OPENAI_API_KEY=$_key'));
      expect(lines, contains('OTHER=x'));
    });
  });
}
