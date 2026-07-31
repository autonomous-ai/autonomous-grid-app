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

  test('the agent gets its own copy, not a pointer at the library — and the '
      'copy names its own scripts, not the library\'s', () async {
    await installHermes();

    for (final skill in const ['grid-image-gen', 'grid-web']) {
      final copy = Directory('${home.path}/.hermes/skills/$skill');
      expect(
        File('${copy.path}/SKILL.md').existsSync(),
        isTrue,
        reason: '$skill must be in the folder Hermes actually reads',
      );
      // Same folder Share writes to, so installing and then sharing by hand
      // rewrites one skill instead of leaving two.
      expect(
        File('${copy.path}/SKILL.md').readAsStringSync(),
        isNot(contains('.grid/skills')),
        reason: "the agent's copy must not run the library's scripts",
      );
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

  test('takes the library back out of Hermes\'s config — a skill reaches an '
      'agent as a copy it was given, not because the whole store is on its '
      'path', () async {
    final config = File('${home.path}/.hermes/config.yaml');
    await config.parent.create(recursive: true);
    // What an older build wrote, and what this one has to undo wherever it
    // lands: with it in place Hermes read every skill in the library, given to
    // it or not, beside the copies the app did make.
    await config.writeAsString(
      'skills:\n  external_dirs:\n    - ~/.grid/skills\n    - ~/work/mine\n',
    );

    await installHermes();

    expect(config.readAsStringSync(), isNot(contains('~/.grid/skills')));
    // An entry the user added by hand is theirs, and stays.
    expect(config.readAsStringSync(), contains('~/work/mine'));
  });

  test('removes the leaked prototypes under creative/, and overwrites the one '
      'sitting where a copy goes today', () async {
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

    // Nothing writes creative/ any more, so what's there is stale and would be
    // read beside the current copy as a second skill of the same name.
    expect(
      Directory(
        '${home.path}/.hermes/skills/creative/grid-image-gen',
      ).existsSync(),
      isFalse,
      reason: 'the superseded creative/ copy must be gone',
    );
    // The root copy is where install writes today: it must survive the cleanup
    // — deleting it left Hermes with no image or video skill at all — and be
    // rewritten, key and all.
    final rewritten = File(
      '${home.path}/.hermes/skills/grid-video-gen/scripts/generate.py',
    );
    expect(rewritten.existsSync(), isTrue);
    expect(rewritten.readAsStringSync(), isNot(contains('eyJleak')));
    expect(script('grid-image-gen').existsSync(), isTrue);
  });

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
