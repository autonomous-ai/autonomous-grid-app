import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/hermes_extensions.dart';
import 'package:grid_app/features/agent/logic/agent_skill_installer.dart';
import 'package:grid_app/features/agent/logic/hermes_skill_scanner.dart';
import 'package:grid_app/features/agents/logic/agent_skill.dart';
import 'package:grid_app/infrastructure/cli/hermes_config_file.dart';
import 'package:grid_app/features/skills/logic/skill_author.dart';
import 'package:grid_app/features/skills/logic/skills_controller.dart';

void main() {
  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('grid_skills_ctrl_test');
  });
  tearDown(() => home.delete(recursive: true));

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        agentSkillScannerProvider.overrideWithValue(
          AgentSkillScanner(home: home.path),
        ),
        skillAuthorProvider.overrideWithValue(SkillAuthor(home: home.path)),
        agentSkillInstallerProvider.overrideWithValue(
          AgentSkillInstaller(home: home.path),
        ),
        // The controller projects the shared store into config.yaml before
        // every authoring write — this must land in the temp home, never in
        // the real ~/.hermes.
        hermesConfigFileProvider.overrideWithValue(
          HermesConfigFile(home: home.path),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('a fresh home lists no skills', () async {
    expect(await container().read(skillsProvider.future), isEmpty);
  });

  test(
    'create writes the skill and the list reflects it without invalidate',
    () async {
      final c = container();
      await c.read(skillsProvider.future);

      final error = await c
          .read(skillsProvider.notifier)
          .create(
            name: 'Weekly report',
            description: 'Writes my weekly report',
            instructions: 'Collect the notes, then summarize.',
          );

      expect(error, isNull);
      final skills = c.read(skillsProvider).value!;
      expect(skills.single.name, 'weekly-report');
      expect(skills.single.isMine, isTrue);
    },
  );

  test('edit under a new name moves the folder', () async {
    final c = container();
    await c.read(skillsProvider.future);
    final notifier = c.read(skillsProvider.notifier);
    await notifier.create(
      name: 'Old name',
      description: 'd',
      instructions: 'i',
    );

    final error = await notifier.edit(
      previousSlug: 'old-name',
      name: 'New name',
      description: 'd',
      instructions: 'i',
    );

    expect(error, isNull);
    expect(c.read(skillsProvider).value!.map((s) => s.name), ['new-name']);
    expect(
      Directory('${home.path}/.grid/skills/my-skills/old-name').existsSync(),
      isFalse,
    );
  });

  test('delete removes the skill from disk and from the list', () async {
    final c = container();
    await c.read(skillsProvider.future);
    final notifier = c.read(skillsProvider.notifier);
    await notifier.create(
      name: 'Gone soon',
      description: 'd',
      instructions: 'i',
    );
    final skill = c.read(skillsProvider).value!.single;

    final error = await notifier.delete(skill);

    expect(error, isNull);
    expect(c.read(skillsProvider).value, isEmpty);
    expect(Directory(skill.path).existsSync(), isFalse);
  });

  test('a refused write comes back as a message, not an exception', () async {
    final c = container();
    await c.read(skillsProvider.future);
    // A path outside the skills root: the author refuses to delete it, and the
    // refusal must reach the button as a line of text.
    final foreign = AgentSkill(
      name: 'foreign',
      description: '',
      path: '${home.path}/elsewhere/not-a-skill',
      fromGrid: false,
    );

    final error = await c.read(skillsProvider.notifier).delete(foreign);

    expect(error, isNotNull);
    expect(error, contains("Couldn't save the skill"));
  });

  test('creating a skill points the agent at the shared store', () async {
    final c = container();
    await c.read(skillsProvider.future);

    await c
        .read(skillsProvider.notifier)
        .create(name: 'Anything', description: 'd', instructions: 'i');

    final config = File('${home.path}/.hermes/config.yaml');
    expect(config.existsSync(), isTrue);
    expect(config.readAsStringSync(), contains('~/.grid/skills'));

    // And the skill itself landed in the shared store, not the agent's own.
    expect(
      Directory('${home.path}/.grid/skills/my-skills/anything').existsSync(),
      isTrue,
    );
  });

  test("reinstall writes Grid's skills and the list shows them", () async {
    final c = container();
    await c.read(skillsProvider.future);

    final error = await c.read(skillsProvider.notifier).reinstallGridSkills();

    expect(error, isNull);
    final skills = c.read(skillsProvider).value!;
    final names = skills.map((s) => s.name).toList();
    expect(names, contains('grid-image-gen'));
    expect(names, contains('grid-video-gen'));
    expect(skills.every((s) => s.fromGrid), isTrue);
  });
}
