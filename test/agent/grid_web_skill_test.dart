import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_skill_installer.dart';
import 'package:grid_app/features/agents/logic/grid_web_skill.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/shared/skills/agent_skill_home.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_web_skill_test');
  });
  tearDown(() => tmp.delete(recursive: true));

  String card() => gridWebSkillMd(
    searchScriptPath: '/skills/grid-web/scripts/search.py',
    readScriptPath: '/skills/grid-web/scripts/read.py',
  );

  group('the grid-web skill card is what makes the agent reach for it', () {
    test('frontmatter names it and says when to use it — the only part the '
        'agent reads to decide', () {
      final md = card();
      expect(md, contains('name: grid-web'));
      // The description carries the intent — search *and* read — since that is
      // what the agent matches against.
      expect(md.toLowerCase(), contains('current'));
      expect(md.toLowerCase(), contains('news'));
      expect(md.toLowerCase(), contains('read'));
    });

    test('spells out both runnable commands, with no package runner in front '
        'of either', () {
      final md = card();
      // Both scripts are standard-library only, so the guide naming a package
      // runner would tell an agent to provision a package nothing uses
      // (public-repo ADR 0036 D-g).
      expect(md, contains('python3 "/skills/grid-web/scripts/search.py"'));
      expect(md, contains('python3 "/skills/grid-web/scripts/read.py"'));
      for (final runner in ['uv', '--with', 'run --no-project']) {
        expect(
          md,
          isNot(contains(runner)),
          reason: 'the web guide still names a package runner: $runner',
        );
      }
    });

    test('the browser fallback is gone from the card, download and all', () {
      // Its whole cost was visible here: a second command, a heavier path to
      // choose between, and a ~170 MB download asked for mid-answer.
      final md = card();
      for (final gone in [
        'browse',
        'playwright',
        'chromium',
        'exit 3',
        'headless',
      ]) {
        expect(md.toLowerCase(), isNot(contains(gone)));
      }
    });

    test('says a JS-built page needs nothing extra — the reason browse could '
        'be deleted at all', () {
      expect(card(), contains('JavaScript'));
      expect(card(), contains('nothing to download'));
    });

    test('is honest that X search needs a login — never sells a partial one as '
        'complete', () {
      expect(card().toLowerCase(), contains('login'));
      expect(card(), contains('X/Twitter'));
    });

    test('both scripts degrade to a typed exit, never a crash', () {
      // Both reach the web through the grid now, and both are exercised by
      // running them (`grid_web_search_script_test.dart`,
      // `grid_web_read_script_test.dart`). What is asserted here is only that
      // each still has a typed exit for "not available here".
      expect(kGridWebSearchScript, contains('return 2'));
      expect(kGridWebReadScript, contains('return 2'));
    });

    test('a page that refused stays distinguishable from a page with nothing '
        'on it', () {
      // The false negative this exists to prevent: an agent told "there is
      // nothing on that page" about a page that turned it away.
      expect(kGridWebReadScript, contains("couldn't read the page"));
      expect(kGridWebReadScript, contains('No readable text found'));
    });
  });
  group('the installer lays the skill down where the agent looks', () {
    test('writes the card and both scripts under the given folder', () async {
      final dir = Directory('${tmp.path}/grid-web');
      await writeSkillFolder(dir, gridWebSkillFiles(dir));

      expect(File('${dir.path}/SKILL.md').existsSync(), isTrue);
      expect(File('${dir.path}/scripts/search.py').existsSync(), isTrue);
      expect(File('${dir.path}/scripts/read.py').existsSync(), isTrue);
      expect(File('${dir.path}/scripts/browse.py').existsSync(), isFalse);
    });

    test('a rewrite wipes the old copy first, so a stale file never lingers '
        'beside the current one', () async {
      final dir = Directory('${tmp.path}/grid-web');
      await writeSkillFolder(dir, gridWebSkillFiles(dir));
      final stale = File('${dir.path}/scripts/old_prototype.py');
      await stale.writeAsString('# left over');

      await writeSkillFolder(dir, gridWebSkillFiles(dir));

      expect(stale.existsSync(), isFalse);
      expect(File('${dir.path}/scripts/search.py').existsSync(), isTrue);
    });
  });

  test(
    'the installer leaves Codex\'s own folder alone — grid-web reaches it as '
    'an MCP guide, and its scripts live in Grid\'s home',
    () async {
      await AgentSkillInstaller(home: tmp.path).install(AgentTool.codex);

      expect(
        Directory('${tmp.path}/.codex/skills/grid-web').existsSync(),
        isFalse,
      );
    },
  );

  test('the installer puts grid-web in the library alongside Grid\'s other '
      'skills for Hermes', () async {
    await AgentSkillInstaller(home: tmp.path).install(AgentTool.hermes);

    final base = '${tmp.path}/.grid/skills/$kPublicSkillsDir';
    expect(File('$base/grid-web/SKILL.md').existsSync(), isTrue);
    // Beside the rest of the registry, not instead of them.
    expect(File('$base/grid-host/SKILL.md').existsSync(), isTrue);
  });
}
