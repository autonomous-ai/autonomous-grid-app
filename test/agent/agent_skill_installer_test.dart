import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/agent_skill_installer.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/shared/skills/agent_skill_home.dart';

void main() {
  late Directory home;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('grid_skill_test');
  });
  tearDown(() => home.delete(recursive: true));

  File script(String skill) => File(
    '${home.path}/.grid/skills/$kPublicSkillsDir/$skill/scripts/generate.py',
  );
  File skillMd(String skill) =>
      File('${home.path}/.grid/skills/$kPublicSkillsDir/$skill/SKILL.md');

  Future<void> installHermes() =>
      AgentSkillInstaller(home: home.path).install(AgentTool.hermes);

  test('installs both the image and video skill files', () async {
    await installHermes();

    for (final skill in const ['grid-image-gen', 'grid-video-gen']) {
      expect(skillMd(skill).existsSync(), isTrue, reason: '$skill SKILL.md');
      expect(script(skill).existsSync(), isTrue, reason: '$skill script');
      expect(skillMd(skill).readAsStringSync(), contains(skill));
    }
  });

  test('neither script bakes credentials or a grid — both read them at run '
      'time from the same OPENAI_* pair', () async {
    await installHermes();

    for (final skill in const ['grid-image-gen', 'grid-video-gen']) {
      final source = script(skill).readAsStringSync();
      // No JWT, no hardcoded grid host — the prototype's leak must not recur.
      expect(source, isNot(contains('eyJ')), reason: '$skill has a baked JWT');
      expect(
        source,
        isNot(contains('grid.autonomous.ai')),
        reason: '$skill hardcodes a grid',
      );
      // Both source the endpoint + key from the environment / ~/.hermes/.env,
      // and from the SAME variables — so switching grids repoints both at once.
      expect(source, contains('OPENAI_BASE_URL'));
      expect(source, contains('OPENAI_API_KEY'));
      expect(source, contains('.hermes/.env'));
    }
  });

  test('the video skill does not read GRID_API_KEY and targets the i2v '
      'endpoint — the exact bug the prototype had', () async {
    await installHermes();
    final source = script('grid-video-gen').readAsStringSync();

    expect(
      source,
      isNot(contains('GRID_API_KEY')),
      reason: 'video must use OPENAI_API_KEY, not the stale GRID_API_KEY',
    );
    expect(source, contains('/media/video/i2v'));
  });

  test('clears the copy the installer used to write into Hermes\'s own '
      'folder — two of one skill and the agent reads the stale one', () async {
    // Where these skills lived before the store: the leaked prototype's
    // hardcoded grid + GRID_API_KEY, plus a references/ dir the clean one
    // doesn't have. Nothing rewrites this copy any more.
    final proto = Directory('${home.path}/.hermes/skills/grid/grid-video-gen');
    await Directory('${proto.path}/references').create(recursive: true);
    await File('${proto.path}/references/api-details.md').writeAsString(
      'Base URL: https://grid.autonomous.ai/grid-1ffe6152a2e547fa/relay/v1\n'
      'API Key: GRID_API_KEY',
    );
    await Directory('${proto.path}/scripts').create(recursive: true);
    await File('${proto.path}/scripts/generate.py').writeAsString(
      'BASE_URL = "https://grid.autonomous.ai/grid-1ffe6152a2e547fa/relay/v1"',
    );

    await installHermes();

    expect(
      Directory('${home.path}/.hermes/skills/grid').existsSync(),
      isFalse,
      reason: 'the superseded copy must not shadow the store',
    );
    // And the clean one is in the store, with no hardcoded grid in it.
    expect(
      script('grid-video-gen').readAsStringSync(),
      isNot(contains('grid-1ffe6152a2e547fa')),
    );
  });

  test('points Hermes at the store before writing into it — skills it '
      'cannot see are not installed', () async {
    await installHermes();

    final config = File('${home.path}/.hermes/config.yaml');
    expect(config.existsSync(), isTrue);
    expect(config.readAsStringSync(), contains('~/.grid/skills'));
  });

  test(
    'removes leaked prototypes under the creative/ and skills root',
    () async {
      for (final leaked in const [
        '.hermes/skills/creative/grid-image-gen',
        '.hermes/skills/grid-video-gen',
      ]) {
        final dir = Directory('${home.path}/$leaked/scripts');
        await dir.create(recursive: true);
        await File(
          '${dir.path}/generate.py',
        ).writeAsString('API_KEY = "eyJleak"');
      }

      await installHermes();

      for (final leaked in const [
        '.hermes/skills/creative/grid-image-gen',
        '.hermes/skills/grid-video-gen',
      ]) {
        expect(
          Directory('${home.path}/$leaked').existsSync(),
          isFalse,
          reason: '$leaked must be gone',
        );
      }
      expect(script('grid-image-gen').existsSync(), isTrue);
    },
  );

  test('is idempotent — a second install keeps both skills', () async {
    await installHermes();
    await installHermes();

    expect(script('grid-image-gen').existsSync(), isTrue);
    expect(script('grid-video-gen').existsSync(), isTrue);
  });

  test('Codex gets web search but not the Hermes-only media skills — the '
      'registry gates each skill by agent', () async {
    await AgentSkillInstaller(home: home.path).install(AgentTool.codex);

    final codexSkills = Directory('${home.path}/.codex/skills');
    expect(
      File('${codexSkills.path}/grid-web/SKILL.md').existsSync(),
      isTrue,
      reason: 'Codex has no other way to reach the web on a grid',
    );
    expect(
      Directory('${codexSkills.path}/grid-image-gen').existsSync(),
      isFalse,
      reason: 'the media skills are Hermes-only today',
    );
    expect(
      Directory('${codexSkills.path}/grid-video-gen').existsSync(),
      isFalse,
    );
  });
}
