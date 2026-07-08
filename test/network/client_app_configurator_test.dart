import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/app_guide_snippets.dart';
import 'package:grid_app/features/network/logic/client_app_configurator.dart';
import 'package:grid_app/features/network/logic/client_app_detector.dart';
import 'package:yaml_edit/yaml_edit.dart';

const _base = 'https://grid.example/relay/v1';
const _key = 'sk-test-123';
const _model = 'qwen3.5:0.8b';

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
      final result = await sut.apply(ClientApp.openClaw, _base, _key, [_model]);

      expect(result, isA<ApplyOk>());
      expect((result as ApplyOk).note, isNull);
      final json = readJson('.openclaw/openclaw.json');
      expect(json['models']['mode'], 'merge');
      final grid = (json['models']['providers'] as Map)['grid'] as Map;
      expect(grid['baseUrl'], _base);
      expect(grid['apiKey'], _key);
      expect((grid['models'] as List).first['id'], _model);
      expect(json['agents']['defaults']['model']['primary'], 'grid/$_model');
    });

    test('writes every grid model to the provider, first as the default',
        () async {
      const ids = ['m-one', 'm-two', 'm-three'];
      await sut.apply(ClientApp.openClaw, _base, _key, ids);

      final json = readJson('.openclaw/openclaw.json');
      final grid = (json['models']['providers'] as Map)['grid'] as Map;
      final listed = (grid['models'] as List).map((m) => m['id']).toList();
      expect(listed, ids); // all of them, not just the first
      expect(json['agents']['defaults']['model']['primary'], 'grid/m-one');
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

      final result = await sut.apply(ClientApp.openClaw, _base, _key, [_model]);

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

      final result = await sut.apply(ClientApp.openClaw, _base, _key, [_model]);
      expect(result, isA<ApplyError>());
    });
  });

  group('Hermes', () {
    String readConfig() =>
        File('${home.path}/.hermes/config.yaml').readAsStringSync();

    test('creates a fresh config.yaml pointing at the grid', () async {
      final result = await sut.apply(ClientApp.hermes, _base, _key, [_model]);

      expect(result, isA<ApplyOk>());
      final editor = YamlEditor(readConfig());
      expect(editor.parseAt(['model', 'provider']).value, 'custom');
      expect(editor.parseAt(['model', 'base_url']).value, _base);
      expect(editor.parseAt(['model', 'api_key']).value, _key);
      expect(editor.parseAt(['model', 'default']).value, _model);
      expect(editor.parseAt(['model', 'max_tokens']).value, kHermesMaxTokens);
      // Registers the grid as a named custom provider.
      expect(editor.parseAt(['custom_providers', 0, 'name']).value,
          'grid.example');
      expect(editor.parseAt(['custom_providers', 0, 'base_url']).value, _base);
      expect(editor.parseAt(['custom_providers', 0, 'api_key']).value, _key);
      expect(editor.parseAt(['custom_providers', 0, 'model']).value, _model);
    });

    test('repoints an existing model block, keeping other settings and a backup',
        () async {
      final config = File('${home.path}/.hermes/config.yaml');
      await config.create(recursive: true);
      // Mirrors a real ollama-launch config: a comment, an unrelated top-level
      // key, and a populated model block we must repoint (not clobber).
      await config.writeAsString(
        '# my hermes config\n'
        'user_profile_enabled: true\n'
        'model:\n'
        '  api_key: ollama\n'
        '  base_url: http://127.0.0.1:11434/v1\n'
        '  default: qwen3.5:0.8b\n'
        '  provider: ollama-launch\n',
      );

      final result = await sut.apply(ClientApp.hermes, _base, _key, [_model]);

      expect(result, isA<ApplyOk>());
      final editor = YamlEditor(readConfig());
      expect(editor.parseAt(['model', 'provider']).value, 'custom');
      expect(editor.parseAt(['model', 'base_url']).value, _base);
      expect(editor.parseAt(['model', 'api_key']).value, _key);
      expect(editor.parseAt(['model', 'default']).value, _model);
      // Registers the grid as a named custom provider (list created fresh).
      expect(editor.parseAt(['custom_providers', 0, 'base_url']).value, _base);
      expect(editor.parseAt(['custom_providers', 0, 'model']).value, _model);
      // Unrelated settings + the comment survive the surgical edit.
      expect(editor.parseAt(['user_profile_enabled']).value, true);
      expect(readConfig(), contains('# my hermes config'));
      expect(File('${config.path}.bak').existsSync(), isTrue);
    });

    test('upserts custom_providers without duplicating or dropping others',
        () async {
      final config = File('${home.path}/.hermes/config.yaml');
      await config.create(recursive: true);
      await config.writeAsString(
        'model:\n'
        '  provider: custom\n'
        'custom_providers:\n'
        '  - name: other\n'
        '    base_url: https://other.example/v1\n'
        '    model: some-model\n',
      );

      await sut.apply(ClientApp.hermes, _base, _key, [_model]);
      await sut.apply(ClientApp.hermes, _base, _key, [_model]); // re-apply

      final editor = YamlEditor(readConfig());
      final list = editor.parseAt(['custom_providers']).value as List;
      expect(list.length, 2); // the other + ours; re-apply doesn't duplicate
      expect(editor.parseAt(['custom_providers', 0, 'name']).value, 'other');
      expect(editor.parseAt(['custom_providers', 1, 'base_url']).value, _base);
    });

    test('overwrites an existing Grid entry when the relay url changed',
        () async {
      final config = File('${home.path}/.hermes/config.yaml');
      await config.create(recursive: true);
      // Same grid (host ⇒ same `name`), but pointed at an older relay url. Only
      // one Grid config may exist per file, so the new url must replace it —
      // not append a second `name: grid.example`.
      await config.writeAsString(
        'model:\n'
        '  provider: custom\n'
        'custom_providers:\n'
        '  - name: grid.example\n'
        '    base_url: https://grid.example/relay/v0\n'
        '    api_key: sk-old\n'
        '    model: old-model\n',
      );

      await sut.apply(ClientApp.hermes, _base, _key, [_model]);

      final editor = YamlEditor(readConfig());
      final list = editor.parseAt(['custom_providers']).value as List;
      expect(list.length, 1); // overwritten in place, no duplicate name
      expect(editor.parseAt(['custom_providers', 0, 'base_url']).value, _base);
      expect(editor.parseAt(['custom_providers', 0, 'api_key']).value, _key);
      expect(editor.parseAt(['custom_providers', 0, 'model']).value, _model);
    });

    test('writes OPENAI_BASE_URL + OPENAI_API_KEY into .env, keeping the rest',
        () async {
      final env = File('${home.path}/.hermes/.env');
      await env.create(recursive: true);
      await env.writeAsString('# my env\nTELEGRAM_BOT_TOKEN=abc\n');

      await sut.apply(ClientApp.hermes, _base, _key, [_model]);

      final lines = env.readAsLinesSync();
      expect(lines, contains('OPENAI_BASE_URL=$_base'));
      expect(lines, contains('OPENAI_API_KEY=$_key'));
      // Unrelated vars + comments survive, and the old file is backed up.
      expect(lines, contains('TELEGRAM_BOT_TOKEN=abc'));
      expect(lines, contains('# my env'));
      expect(File('${env.path}.bak').existsSync(), isTrue);
    });

    test('upserts an existing OPENAI_API_KEY line instead of duplicating it',
        () async {
      final env = File('${home.path}/.hermes/.env');
      await env.create(recursive: true);
      await env.writeAsString('OPENAI_API_KEY=old\nOTHER=keep\n');

      await sut.apply(ClientApp.hermes, _base, _key, [_model]);

      final content = env.readAsStringSync();
      expect('OPENAI_API_KEY='.allMatches(content).length, 1); // no duplicate
      expect(content, contains('OPENAI_API_KEY=$_key'));
      expect(content, contains('OTHER=keep'));
    });

    test('leaves commented template lines alone and appends a real one',
        () async {
      final env = File('${home.path}/.hermes/.env');
      await env.create(recursive: true);
      await env.writeAsString('# OPENAI_API_KEY=sk-example\n');

      await sut.apply(ClientApp.hermes, _base, _key, [_model]);

      final lines = env.readAsLinesSync();
      // The template comment is preserved…
      expect(lines, contains('# OPENAI_API_KEY=sk-example'));
      // …and a real, uncommented assignment is appended.
      expect(lines, contains('OPENAI_API_KEY=$_key'));
    });
  });
}
