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
    uvPath: '/grid/bin/uv',
    searchScriptPath: '/skills/grid-web/scripts/search.py',
    readScriptPath: '/skills/grid-web/scripts/read.py',
    browseScriptPath: '/skills/grid-web/scripts/browse.py',
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

    test('spells out all three runnable commands with the real uv and script '
        'paths', () {
      final md = card();
      // Search runs through no package runner at all: it is standard-library
      // only now, and the guide naming `uv` would tell an agent to provision a
      // package nothing uses (public-repo ADR 0036 D-g).
      expect(md, contains('python3 "/skills/grid-web/scripts/search.py"'));
      expect(
        md,
        isNot(contains('uv" run --with ddgs')),
        reason: 'the search command still names a package runner',
      );
      expect(
        md,
        contains(
          '"/grid/bin/uv" run --with trafilatura python3 '
          '"/skills/grid-web/scripts/read.py"',
        ),
      );
      expect(
        md,
        contains(
          '"/grid/bin/uv" run --with playwright --with trafilatura python3 '
          '"/skills/grid-web/scripts/browse.py"',
        ),
      );
      // The one-time browser download is named, so the agent can run it rather
      // than dead-end when browse reports it's needed.
      expect(md, contains('playwright install chromium'));
    });

    test('leads with the light tools and marks browse as the heavy fallback — '
        'so the agent tries read before spinning up a browser', () {
      expect(card(), contains('try `read` first'));
      expect(card().toLowerCase(), contains('heavier'));
    });

    test('is honest that X search needs a login — never sells a partial one as '
        'complete', () {
      expect(card().toLowerCase(), contains('login'));
      expect(card(), contains('X/Twitter'));
    });

    test('all three scripts degrade to a typed exit, never a crash', () {
      // Search reaches the web through the grid now — its behaviour is covered
      // by running it (`grid_web_search_script_test.dart`); what is asserted
      // here is only that it still has a typed exit for "not available".
      expect(kGridWebSearchScript, contains('return 2'));
      // Read pulls the article body, then falls back to page metadata (a tweet's
      // text lives there), and never throws on a missing reader.
      expect(kGridWebReadScript, contains('import trafilatura'));
      expect(kGridWebReadScript, contains('extract_metadata'));
      expect(kGridWebReadScript, contains('return 2'));
      // Browse detects a missing browser and asks for the one-time install
      // (exit 3) rather than blocking a turn on a silent download.
      expect(kGridWebBrowseScript, contains('sync_playwright'));
      expect(kGridWebBrowseScript, contains('return 3'));
    });
  });

  group('the installer lays the skill down where the agent looks', () {
    test('writes the card and both scripts under the given folder', () async {
      final dir = Directory('${tmp.path}/grid-web');
      await writeSkillFolder(dir, gridWebSkillFiles(dir, uvPath: '/uv'));

      expect(File('${dir.path}/SKILL.md').existsSync(), isTrue);
      expect(File('${dir.path}/scripts/search.py').existsSync(), isTrue);
      expect(File('${dir.path}/scripts/read.py').existsSync(), isTrue);
      expect(File('${dir.path}/scripts/browse.py').existsSync(), isTrue);
    });

    test('a rewrite wipes the old copy first, so a stale file never lingers '
        'beside the current one', () async {
      final dir = Directory('${tmp.path}/grid-web');
      await writeSkillFolder(dir, gridWebSkillFiles(dir, uvPath: '/uv'));
      final stale = File('${dir.path}/scripts/old_prototype.py');
      await stale.writeAsString('# left over');

      await writeSkillFolder(dir, gridWebSkillFiles(dir, uvPath: '/uv'));

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
