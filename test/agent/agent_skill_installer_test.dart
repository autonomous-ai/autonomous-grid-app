import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_skill_installer.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/shared/skills/agent_skill_home.dart';

void main() {
  late Directory home;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('grid_skill_test');
  });
  tearDown(() => home.delete(recursive: true));

  File skillMd(String skill) =>
      File('${home.path}/.grid/skills/$kPublicSkillsDir/$skill/SKILL.md');

  Future<void> installHermes() =>
      AgentSkillInstaller(home: home.path).install(AgentTool.hermes);

  // Not the whole registry: a card can be written for one agent — `grid-delegate`
  // teaches a flag only Claude Code's spawner has — and installing for Hermes
  // is not supposed to write it anywhere.
  final hermesSkills = kBuiltinGridSkills.where(
    (skill) => skill.appliesTo(AgentTool.hermes),
  );

  test('installs every skill in the registry, card and scripts', () async {
    await installHermes();

    for (final skill in hermesSkills) {
      expect(
        skillMd(skill.name).existsSync(),
        isTrue,
        reason: '${skill.name} SKILL.md',
      );
      expect(skillMd(skill.name).readAsStringSync(), contains(skill.name));
    }
  });

  test('the agent gets its own copy, not a pointer at the library — and the '
      'copy names its own scripts, not the library\'s', () async {
    await installHermes();

    for (final skill in const ['grid-web', 'grid-serve']) {
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

  test('an unchanged skill is not written again — the "Last updated" the '
      'screen sorts by must mean the user, not the last launch', () async {
    await installHermes();
    final card = File('${home.path}/.hermes/skills/grid-web/SKILL.md');
    // Stamped into the past rather than compared against the clock: two
    // installs in one test can land in the same millisecond, and a test that
    // passes because the write was fast proves nothing.
    final untouched = DateTime(2026, 1, 1);
    card.setLastModifiedSync(untouched);

    await installHermes();

    expect(card.lastModifiedSync(), untouched);
  });

  test('a card that no longer matches this build is put back — a fixed card '
      'has to reach a machine that already has the skill', () async {
    // What this cost when it didn't: `grid-serve`, `grid-host` and `grid-web`
    // shipped with front-matter Codex rejects, so it dropped all three from the
    // skill list it shows the model — and no later build could have replaced
    // them, because the installer only asked whether the folder existed.
    await installHermes();
    final card = File('${home.path}/.hermes/skills/grid-web/SKILL.md');
    await card.writeAsString('---\nname: grid-web\ndescription: mine\n---\n');

    await installHermes();

    expect(card.readAsStringSync(), isNot(contains('description: mine')));
    expect(card.readAsStringSync(), contains('Search the web'));
  });

  test('a stale script is replaced too — a card can match while the code it '
      'runs is three builds old', () async {
    await installHermes();
    final script = File(
      '${home.path}/.hermes/skills/grid-serve/scripts/serve.py',
    );
    await script.writeAsString('print("old")\n');

    await installHermes();

    expect(script.readAsStringSync(), contains('serve.py start'));
  });

  test('clears the copy the installer used to write into Hermes\'s own '
      'folder — two of one skill and the agent reads the stale one', () async {
    // Where these skills lived before the store: a folder of its own under
    // `skills/grid/`. Nothing rewrites that copy any more.
    final proto = Directory('${home.path}/.hermes/skills/grid/grid-web');
    await Directory('${proto.path}/scripts').create(recursive: true);
    await File(
      '${proto.path}/scripts/search.py',
    ).writeAsString('BASE_URL = "https://grid.autonomous.ai/grid-1ffe6152"');

    await installHermes();

    expect(
      Directory('${home.path}/.hermes/skills/grid').existsSync(),
      isFalse,
      reason: 'the superseded copy must not shadow the store',
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

  test('removes the leaked prototypes under creative/, which baked a live key '
      'into their scripts', () async {
    final dir = Directory(
      '${home.path}/.hermes/skills/creative/grid-image-gen/scripts',
    );
    await dir.create(recursive: true);
    await File('${dir.path}/generate.py').writeAsString('API_KEY = "eyJleak"');

    await installHermes();

    expect(
      Directory(
        '${home.path}/.hermes/skills/creative/grid-image-gen',
      ).existsSync(),
      isFalse,
      reason: 'the superseded creative/ copy must be gone',
    );
  });

  test('takes a withdrawn skill off the machine — off every agent it was '
      'copied to, and out of the library', () async {
    Future<void> plant(String path) async {
      final dir = Directory('${home.path}/$path');
      await dir.create(recursive: true);
      await File('${dir.path}/SKILL.md').writeAsString('---\nname: x\n---\n');
    }

    // Where the two media skills landed while Grid shipped them: the library,
    // Hermes's own folder, and — for anyone who used Share — another agent's.
    await plant('.grid/skills/$kPublicSkillsDir/grid-image-gen');
    await plant('.hermes/skills/grid-image-gen');
    await plant('.hermes/skills/grid-video-gen');
    await plant('.codex/skills/grid-video-gen');

    await installHermes();
    await AgentSkillInstaller(home: home.path).install(AgentTool.codex);

    for (final gone in const [
      '.grid/skills/$kPublicSkillsDir/grid-image-gen',
      '.hermes/skills/grid-image-gen',
      '.hermes/skills/grid-video-gen',
      '.codex/skills/grid-video-gen',
    ]) {
      expect(
        Directory('${home.path}/$gone').existsSync(),
        isFalse,
        reason: '$gone would keep firing on instructions nobody maintains',
      );
    }
  });

  test('retires nothing the registry still installs — a live name on that list '
      'deletes the skill install had just written', () {
    final installed = {for (final skill in kBuiltinGridSkills) skill.name};

    expect(installed.intersection(kRetiredGridSkills.toSet()), isEmpty);
  });

  test('is idempotent — a second install keeps every skill', () async {
    await installHermes();
    await installHermes();

    for (final skill in hermesSkills) {
      expect(skillMd(skill.name).existsSync(), isTrue, reason: skill.name);
    }
  });

  test('each agent gets the skills the registry gives it, in its own '
      'folder', () async {
    await AgentSkillInstaller(home: home.path).install(AgentTool.codex);

    final codexSkills = Directory('${home.path}/.codex/skills');
    for (final skill in kBuiltinGridSkills.where(
      (s) => s.appliesTo(AgentTool.codex),
    )) {
      expect(
        File('${codexSkills.path}/${skill.name}/SKILL.md').existsSync(),
        isTrue,
        reason: '${skill.name} is registered for Codex',
      );
    }
    // And nothing the registry withheld: a card naming a flag Codex's runtime
    // does not have would be advice it can only follow by inventing one.
    for (final skill in kBuiltinGridSkills.where(
      (s) => !s.appliesTo(AgentTool.codex),
    )) {
      expect(
        File('${codexSkills.path}/${skill.name}/SKILL.md').existsSync(),
        isFalse,
        reason: '${skill.name} is not registered for Codex',
      );
    }
    // Nothing was written for an agent that wasn't asked for.
    expect(Directory('${home.path}/.claude/skills').existsSync(), isFalse);
  });
}
