import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_skill_installer.dart';
import 'package:grid_app/features/agents/logic/grid_host_skill.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/shared/skills/agent_skill_home.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_host_skill_test');
  });
  tearDown(() => tmp.delete(recursive: true));

  String card() => gridHostSkillMd(uvPath: '/grid/bin/uv');

  group('the card fires before the mistake, not after it', () {
    test('it triggers on the intent as well as the aftermath — a card that '
        'only fires on "command not found" saves nothing', () {
      final md = card();

      expect(md, contains('name: grid-host'));
      final frontmatter = md.split('---')[1].toLowerCase();
      expect(frontmatter, contains('command not found'));
      expect(frontmatter, contains('timeout'));
      expect(frontmatter, contains('install'));
    });

    test('each missing tool is paired with what to use instead — the three the '
        'agents actually wasted calls on', () {
      final md = card();

      for (final missing in ['timeout', 'gh', 'rg', 'setsid', 'tmux']) {
        expect(
          md,
          contains(missing),
          reason: '$missing is not on this machine',
        );
      }
      // The substitutes, not just the absences.
      expect(md, contains('grep -rn'));
      expect(md, contains('grid-serve'));
      expect(md, contains('"/grid/bin/uv" run --no-project python3'));
    });

    test('it tells the agent to verify rather than trust a fixed inventory, so '
        'installing gh tomorrow does not turn the card into a lie', () {
      expect(card(), contains('command -v'));
    });

    test('node coming from nvm is named as a PATH problem, which is what makes '
        'a launchd job fail with "node: command not found"', () {
      final flat = card().replaceAll(RegExp(r'\s+'), ' ');

      expect(flat, contains('nvm'));
      expect(flat, contains('node: command not found'));
    });

    test('installing anything is gated on asking the user — an unattended brew '
        'install is not the agent\'s call to make', () {
      final flat = card().replaceAll(RegExp(r'\s+'), ' ');

      expect(flat, contains('Never install unattended'));
      expect(flat, contains('sudo'));
      expect(flat, contains('ask the user'));
    });
  });

  test('it is a card with nothing to run, and lands for both agents', () async {
    final files = gridHostSkillFiles(Directory('${tmp.path}/x'), uvPath: '/uv');
    expect(files.files, isEmpty);

    for (final agent in AgentTool.values) {
      await AgentSkillInstaller(home: tmp.path).install(agent);
    }
    expect(
      File('${tmp.path}/.codex/skills/grid-host/SKILL.md').existsSync(),
      isTrue,
    );
    expect(
      File(
        '${tmp.path}/.grid/skills/$kPublicSkillsDir/grid-host/SKILL.md',
      ).existsSync(),
      isTrue,
    );
  });
}
