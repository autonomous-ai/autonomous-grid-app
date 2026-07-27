import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/codex_skill_installer.dart';
import 'package:grid_app/features/agent/logic/grid_web_skill.dart';
import 'package:grid_app/features/agent/logic/hermes_skill_installer.dart';

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

    test('spells out both runnable commands with the real uv and script paths',
        () {
      final md = card();
      expect(
        md,
        contains(
          '"/grid/bin/uv" run --with ddgs python3 '
          '"/skills/grid-web/scripts/search.py"',
        ),
      );
      expect(
        md,
        contains(
          '"/grid/bin/uv" run --with trafilatura python3 '
          '"/skills/grid-web/scripts/read.py"',
        ),
      );
    });

    test('is honest that X search needs a login — never sells a partial one as '
        'complete', () {
      expect(card().toLowerCase(), contains('login'));
      expect(card(), contains('X/Twitter'));
    });

    test('both scripts degrade to a typed exit, never a crash', () {
      expect(kGridWebSearchScript, contains('from ddgs import DDGS'));
      expect(kGridWebSearchScript, contains('return 2'));
      // Read pulls the article body, then falls back to page metadata (a tweet's
      // text lives there), and never throws on a missing reader.
      expect(kGridWebReadScript, contains('import trafilatura'));
      expect(kGridWebReadScript, contains('extract_metadata'));
      expect(kGridWebReadScript, contains('return 2'));
    });
  });

  group('writeGridWebSkill lays the skill down where the agent looks', () {
    test('writes the card and both scripts under the given folder', () async {
      final dir = Directory('${tmp.path}/grid-web');
      await writeGridWebSkill(dir, uvPath: '/uv');

      expect(File('${dir.path}/SKILL.md').existsSync(), isTrue);
      expect(File('${dir.path}/scripts/search.py').existsSync(), isTrue);
      expect(File('${dir.path}/scripts/read.py').existsSync(), isTrue);
    });

    test('a rewrite wipes the old copy first, so a stale file never lingers '
        'beside the current one', () async {
      final dir = Directory('${tmp.path}/grid-web');
      await writeGridWebSkill(dir, uvPath: '/uv');
      final stale = File('${dir.path}/scripts/old_prototype.py');
      await stale.writeAsString('# left over');

      await writeGridWebSkill(dir, uvPath: '/uv');

      expect(stale.existsSync(), isFalse);
      expect(File('${dir.path}/scripts/search.py').existsSync(), isTrue);
    });
  });

  test('CodexSkillInstaller drops grid-web where Codex auto-discovers skills',
      () async {
    await CodexSkillInstaller(home: tmp.path).install();

    final skill = Directory('${tmp.path}/.codex/skills/grid-web');
    expect(File('${skill.path}/SKILL.md').existsSync(), isTrue);
    expect(File('${skill.path}/scripts/search.py').existsSync(), isTrue);
    expect(File('${skill.path}/scripts/read.py').existsSync(), isTrue);
  });

  test('HermesSkillInstaller installs grid-web alongside the media skills',
      () async {
    await HermesSkillInstaller(home: tmp.path).install();

    final base = '${tmp.path}/.hermes/skills/grid';
    expect(File('$base/grid-web/SKILL.md').existsSync(), isTrue);
    // The existing media skills are untouched.
    expect(File('$base/grid-image-gen/SKILL.md').existsSync(), isTrue);
  });
}
