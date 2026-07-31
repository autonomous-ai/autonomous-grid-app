import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/hermes_extensions.dart';
import 'package:grid_app/features/agent/logic/agent_skill_installer.dart';
import 'package:grid_app/features/agent/logic/hermes_skill_scanner.dart';
import 'package:grid_app/features/agents/logic/agent_skill.dart';
import 'package:grid_app/infrastructure/cli/hermes_config_file.dart';
import 'package:grid_app/features/skills/logic/skill_author.dart';
import 'package:grid_app/features/skills/logic/skill_sharing.dart';
import 'package:grid_app/features/skills/logic/skills_controller.dart';
import 'package:grid_app/shared/skills/agent_skill_home.dart';

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
        // Adding a skill hands a copy to an agent — into the temp home, never
        // the developer's own ~/.hermes/skills.
        skillSharerProvider.overrideWithValue(SkillSharer(home: home.path)),
      ],
    );
    // Both skills providers auto-dispose, and nothing here is a widget: without
    // a listener the notifier is gone the moment its first read completes, and
    // every write after that would run on a disposed Ref — a test artefact, not
    // what the app does with the screen open.
    c.listen(skillsProvider, (_, _) {});
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
      // A write lands the screen on the folder the skill was given to, which
      // rebuilds the list — so the fresh read is the one to assert on.
      final skills = await c.read(skillsProvider.future);
      expect(skills.map((s) => s.name), contains('weekly-report'));
    },
  );

  test('edit under a new name moves the folder in the store', () async {
    final c = container();
    await c.read(skillsProvider.future);
    final notifier = c.read(skillsProvider.notifier);
    await notifier.create(
      name: 'Old name',
      description: 'd',
      instructions: 'i',
    );
    // The write landed the screen on Hermes's folder (its copy). The rename is
    // about the original, so read the store back.
    c.read(skillSourceProvider.notifier).select(SkillSource.store);
    await c.read(skillsProvider.future);

    final error = await notifier.edit(
      previousPath: '${home.path}/.grid/skills/$kUserSkillsDir/old-name',
      name: 'New name',
      description: 'd',
      instructions: 'i',
    );

    expect(error, isNull);
    expect(
      (await c.read(skillsProvider.future)).map((s) => s.name),
      contains('new-name'),
    );
    expect(
      Directory(
        '${home.path}/.grid/skills/$kUserSkillsDir/old-name',
      ).existsSync(),
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
    expect(await c.read(skillsProvider.future), isEmpty);
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
      owner: SkillOwner.user,
      updatedAt: DateTime(2026, 7, 30),
    );

    final error = await c.read(skillsProvider.notifier).delete(foreign);

    expect(error, isNotNull);
    // The writer's own sentence, in the user's words — not "Couldn't save the
    // skill: Invalid argument(s)" with a temp path stapled to it.
    expect(error, contains("isn't in one of Grid's skill folders"));
    expect(error, isNot(contains(home.path)));
  });

  test('a new skill reaches the agent as a copy, and never by pointing it at '
      'the whole library', () async {
    final c = container();
    await c.read(skillsProvider.future);

    await c
        .read(skillsProvider.notifier)
        .create(name: 'Anything', description: 'd', instructions: 'i');

    // The original belongs to the app's own store, which no agent reads
    // wholesale: an entry for it in `external_dirs` would make every skill in
    // the library live for Hermes, given to it or not.
    expect(
      Directory(
        '${home.path}/.grid/skills/$kUserSkillsDir/anything',
      ).existsSync(),
      isTrue,
    );
    final config = File('${home.path}/.hermes/config.yaml');
    expect(
      config.existsSync() ? config.readAsStringSync() : '',
      isNot(contains('~/.grid/skills')),
    );

    // What the agent gets is one copy, in its own folder.
    expect(
      Directory('${home.path}/.hermes/skills/anything').existsSync(),
      isTrue,
    );
  });

  test("reinstall writes Grid's skills and the list shows them", () async {
    final c = container();
    await c.read(skillsProvider.future);

    final error = await c.read(skillsProvider.notifier).reinstallGridSkills();

    expect(error, isNull);
    final skills = await c.read(skillsProvider.future);
    final names = skills.map((s) => s.name).toList();
    expect(names, contains('grid-image-gen'));
    expect(names, contains('grid-video-gen'));
    expect(skills.every((s) => s.owner == SkillOwner.public), isTrue);
  });

  group('the folder the screen is on', () {
    Future<void> writeSkill(String path, String name) async {
      final dir = Directory('${home.path}/$path');
      await dir.create(recursive: true);
      await File(
        '${dir.path}/SKILL.md',
      ).writeAsString('---\nname: $name\ndescription: d\n---\n');
    }

    test('each pill reads that folder and no other — the screen opens on the '
        'chat assistant\'s own', () async {
      await writeSkill('.grid/skills/$kUserSkillsDir/mine', 'mine');
      await writeSkill('.hermes/skills/apple/apple-notes', 'apple-notes');
      await writeSkill('.codex/skills/review-pr', 'review-pr');
      final c = container();

      // Hermes by default: the agent the app installs and chats through.
      expect((await c.read(skillsProvider.future)).map((s) => s.name), [
        'apple-notes',
      ]);

      c.read(skillSourceProvider.notifier).select(SkillSource.store);
      expect((await c.read(skillsProvider.future)).map((s) => s.name), [
        'mine',
      ]);

      c.read(skillSourceProvider.notifier).select(SkillSource.codex);
      expect((await c.read(skillsProvider.future)).map((s) => s.name), [
        'review-pr',
      ]);
    });

    test('a new skill is kept in the store and shown on the folder of the '
        'assistant it was given to — otherwise it looks like it vanished',
        () async {
      await writeSkill('.hermes/skills/apple/apple-notes', 'apple-notes');
      final c = container();
      // Reading the store when the write happens, so the landing has somewhere
      // to move the screen to.
      c.read(skillSourceProvider.notifier).select(SkillSource.store);
      await c.read(skillsProvider.future);

      final error = await c
          .read(skillsProvider.notifier)
          .create(name: 'Weekly report', description: 'd', instructions: 'i');

      expect(error, isNull);
      // Hermes is the default recipient, so that is the folder to show.
      expect(c.read(skillSourceProvider), SkillSource.hermes);
      expect(
        (await c.read(skillsProvider.future)).map((s) => s.name),
        containsAll(['apple-notes', 'weekly-report']),
      );
      // The original stays in the app's own store — the copy is what the agent
      // reads.
      expect(
        Directory(
          '${home.path}/.grid/skills/$kUserSkillsDir/weekly-report',
        ).existsSync(),
        isTrue,
      );
    });
  });
}
