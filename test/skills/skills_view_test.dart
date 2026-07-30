import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/agent_skill_installer.dart';
import 'package:grid_app/features/agent/logic/hermes_extensions.dart';
import 'package:grid_app/features/agent/logic/hermes_skill_scanner.dart';
import 'package:grid_app/features/agent/logic/hermes_tool.dart';
import 'package:grid_app/features/skills/logic/skill_author.dart';
import 'package:grid_app/features/skills/logic/skill_sharing.dart';
import 'package:grid_app/features/skills/logic/skills_controller.dart';
import 'package:grid_app/features/skills/presentation/skills_view.dart';
import 'package:grid_app/infrastructure/cli/hermes_config_file.dart';
import 'package:grid_app/shared/skills/agent_skill_home.dart';

/// The Skills screen as the user meets it: which folder it opens on, and that
/// opening it at all doesn't throw.
///
/// The last point is not hypothetical — an earlier attempt at "always start on
/// Shared" reset the pill from `initState`, which Riverpod rejects outright, and
/// the whole screen came up as a red error page. A widget test is the only thing
/// that catches that; the unit tests were all green.
void main() {
  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('grid_skills_view_test');
  });
  tearDown(() => home.delete(recursive: true));

  Future<void> writeSkill(String path, String name) async {
    final dir = Directory('${home.path}/$path');
    await dir.create(recursive: true);
    await File(
      '${dir.path}/SKILL.md',
    ).writeAsString('---\nname: $name\ndescription: what it does\n---\n');
  }

  Future<ProviderContainer> pumpSkills(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        // The screen is gated on the agent being installed; a path is all that
        // gate reads.
        hermesPathProvider.overrideWithValue('/bin/hermes'),
        agentSkillScannerProvider.overrideWithValue(
          AgentSkillScanner(home: home.path),
        ),
        skillAuthorProvider.overrideWithValue(SkillAuthor(home: home.path)),
        agentSkillInstallerProvider.overrideWithValue(
          AgentSkillInstaller(home: home.path),
        ),
        hermesConfigFileProvider.overrideWithValue(
          HermesConfigFile(home: home.path),
        ),
        // Adding a skill hands a copy to an agent — into the temp home, never
        // the developer's own ~/.hermes/skills.
        skillSharerProvider.overrideWithValue(SkillSharer(home: home.path)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SkillsView())),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('opens on the store, and offers the other two folders', (
    tester,
  ) async {
    await writeSkill('.grid/skills/$kUserSkillsDir/mine', 'mine');
    await writeSkill('.hermes/skills/apple/apple-notes', 'apple-notes');

    final container = await pumpSkills(tester);

    expect(container.read(skillSourceProvider), SkillSource.store);
    expect(find.text('Shared'), findsOneWidget);
    expect(find.text('Hermes'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('mine'), findsOneWidget);
    expect(find.text('apple-notes'), findsNothing);
  });

  testWidgets('a pill switches folders, and the author column names whose '
      'skills they are', (tester) async {
    await writeSkill('.grid/skills/$kUserSkillsDir/mine', 'mine');
    await writeSkill('.hermes/skills/apple/apple-notes', 'apple-notes');
    await pumpSkills(tester);

    await tester.tap(find.text('Hermes'));
    await tester.pumpAndSettle();

    expect(find.text('apple-notes'), findsOneWidget);
    expect(find.text('mine'), findsNothing);
    // Every row in this folder is the agent's, so the column reads the same.
    expect(find.text('hermes'), findsOneWidget);
    // And nothing in it is offered for editing.
    expect(find.byTooltip('Edit'), findsNothing);
    expect(find.byTooltip('Delete'), findsNothing);
  });

  testWidgets('the store\'s own rows say who wrote them, and only the '
      'user\'s can be changed', (tester) async {
    await writeSkill('.grid/skills/$kUserSkillsDir/mine', 'mine');
    await writeSkill('.grid/skills/$kPublicSkillsDir/grid-web', 'grid-web');

    await pumpSkills(tester);

    expect(find.text('You'), findsOneWidget);
    expect(find.text('public'), findsOneWidget);
    // One editable row — the user's — not two.
    expect(find.byTooltip('Edit'), findsOneWidget);
  });

  testWidgets('clicking a row opens the folder behind the skill, not just '
      'the card', (tester) async {
    final dir = Directory(
      '${home.path}/.grid/skills/$kPublicSkillsDir/grid-image-gen',
    );
    await Directory('${dir.path}/scripts').create(recursive: true);
    await File('${dir.path}/SKILL.md').writeAsString(
      '---\nname: grid-image-gen\ndescription: Make a picture.\n---\n\n'
      '# Generate an image\n\nRun the bundled script.\n',
    );
    await File(
      '${dir.path}/scripts/generate.py',
    ).writeAsString('print("hello from the script")\n');
    await pumpSkills(tester);

    await tester.tap(find.text('grid-image-gen'));
    await tester.pumpAndSettle();

    // The card is what it opens on, rendered.
    expect(find.text('by public · 2 files'), findsOneWidget);
    expect(find.text('Generate an image'), findsOneWidget);
    // And the script beside it is there to be read.
    expect(find.text('generate.py'), findsOneWidget);
    await tester.tap(find.text('generate.py'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('hello from the script'),
      findsOneWidget,
      reason: 'a script has no rendered form — it shows as it is on disk',
    );
  });

  testWidgets('leaving the screen puts the pill back on Shared', (
    tester,
  ) async {
    await writeSkill('.hermes/skills/apple/apple-notes', 'apple-notes');
    final container = await pumpSkills(tester);

    await tester.tap(find.text('Hermes'));
    await tester.pumpAndSettle();
    expect(container.read(skillSourceProvider), SkillSource.hermes);

    // Close the screen the way the shell does — the pane is swapped out — then
    // come back to it.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SizedBox())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SkillsView())),
      ),
    );
    await tester.pumpAndSettle();

    expect(container.read(skillSourceProvider), SkillSource.store);
  });
}
