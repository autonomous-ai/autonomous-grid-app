import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_skill_installer.dart';
import 'package:grid_app/features/agents/logic/grid_serve_skill.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/shared/skills/agent_skill_home.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_serve_skill_test');
  });
  tearDown(() => tmp.delete(recursive: true));

  String card() => gridServeSkillMd(
    uvPath: '/grid/bin/uv',
    serveScriptPath: '/skills/grid-serve/scripts/serve.py',
    stateDir: '/home/.grid/app/services',
  );

  group('the card is what decides whether the agent reaches for this', () {
    test('the description covers how a user actually asks — including "why '
        'does localhost not answer", which is how they meet the bug', () {
      final md = card().toLowerCase();

      expect(md, contains('name: grid-serve'));
      expect(md, contains('start'));
      expect(md, contains('server'));
      expect(md, contains('localhost'));
      expect(md, contains('stop'));
      // "Run the app", not only "start a server": the user who lost an
      // afternoon to this asked for an Electron app to be run, and a
      // description that only said "server" is one an agent can read past.
      expect(md, contains('run the app'));
      expect(md, contains('desktop app'));
    });

    test('the front matter carries name and description and nothing else — '
        'Codex drops a skill whose front matter has a key it does not '
        'know, and says nothing', () {
      // What that cost: this card shipped with `tags:` and `triggers:`, so it
      // was missing from the skill list Codex shows the model for ten days,
      // while a user spent an afternoon on the exact bug it prevents.
      final front = card().split('---')[1].trim().split('\n');
      final keys = [
        for (final line in front)
          if (!line.startsWith(' ') && line.contains(':'))
            line.split(':').first,
      ];

      expect(keys, ['name', 'description']);
    });

    test('it names the trap first: a server started with nohup looks alive and '
        'is dead by the time the user clicks', () {
      final md = card();
      // The card is hard-wrapped at 80 columns, so a sentence spans lines;
      // flatten the whitespace to assert on the prose rather than the wrapping.
      final flat = md.replaceAll(RegExp(r'\s+'), ' ');

      expect(md, contains('nohup'));
      expect(md, contains('disown'));
      expect(md, contains('setsid'));
      expect(
        flat,
        contains('kills the moment your tool call returns'),
        reason: 'the agent must be told why, or it will keep trying nohup',
      );
    });

    test('every command is spelled with the real uv and script path — a card '
        'that says "run serve.py" leaves the agent guessing', () {
      final md = card();
      const prefix =
          '"/grid/bin/uv" run --no-project python3 '
          '"/skills/grid-serve/scripts/serve.py"';

      expect(md, contains('$prefix start <name>'));
      expect(md, contains('$prefix status [<name>]'));
      expect(md, contains('$prefix logs <name> [-n 80]'));
      expect(md, contains('$prefix stop <name>'));
      expect(md, contains('$prefix port <port> [--release]'));
      expect(md, contains('$prefix run <name>'));
      expect(md, contains('/home/.grid/app/services'));
    });

    test('it points EADDRINUSE at the port command and names `run` as the '
        'substitute for the `timeout` macOS lacks', () {
      final flat = card().replaceAll(RegExp(r'\s+'), ' ');

      expect(flat, contains('EADDRINUSE'));
      expect(
        flat,
        contains('substitute for `timeout`'),
        reason: 'the agents reached for GNU timeout 30 times in 83 turns',
      );
      // Releasing a port must never mean killing a stranger's program.
      expect(flat, contains('only** if this skill started it'));
    });

    test('it forbids announcing a URL the port never answered on — the exact '
        'thing that made a dead server read as a working one', () {
      expect(card(), contains('only if the port answered'));
    });
  });

  group('what lands on disk', () {
    test('the card names the script by the path it is actually written to, so '
        'the command it prints can be run verbatim', () {
      final dir = Directory('${tmp.path}/.codex/skills/grid-serve');

      final files = gridServeSkillFiles(dir, uvPath: '/uv', stateDir: '/svc');

      expect(files.files.keys, ['scripts/serve.py']);
      expect(files.card, contains('"${dir.path}/scripts/serve.py"'));
    });

    test('the script is a runnable python program with the four commands the '
        'card promises', () {
      expect(kGridServeScript, startsWith('#!/usr/bin/env python3'));
      for (final command in [
        '"start"',
        '"status"',
        '"logs"',
        '"stop"',
        '"port"',
        '"run"',
      ]) {
        expect(
          kGridServeScript,
          contains('add_parser($command'),
          reason: 'the card documents $command',
        );
      }
      // The supervisors, in the order the script tries them.
      expect(kGridServeScript, contains('launchctl'));
      expect(kGridServeScript, contains('screen'));
      expect(kGridServeScript, contains('tmux'));
      // The started command must carry the agent's PATH: a launchd job gets a
      // minimal one and would not find a version-managed node.
      expect(kGridServeScript, contains('export PATH='));
    });

    test('installing writes it where each agent looks: Codex flat in its own '
        'folder, Hermes in the store\'s public one', () async {
      for (final agent in AgentTool.values) {
        await AgentSkillInstaller(home: tmp.path).install(agent);
      }

      final codex = File('${tmp.path}/.codex/skills/grid-serve/SKILL.md');
      final hermes = File(
        '${tmp.path}/.grid/skills/$kPublicSkillsDir/grid-serve/SKILL.md',
      );
      expect(codex.existsSync(), isTrue);
      expect(hermes.existsSync(), isTrue);
      expect(
        File(
          '${tmp.path}/.codex/skills/grid-serve/scripts/serve.py',
        ).existsSync(),
        isTrue,
      );
      // Same skill, same words, whichever agent is answering.
      expect(codex.readAsStringSync(), contains('name: grid-serve'));
      expect(hermes.readAsStringSync(), contains('name: grid-serve'));
    });

    test('a successful stop drops the record, so the app stops listing a '
        'service that is gone — the Stop that looked like it did nothing '
        '(#42)', () {
      // The running-services bar shows one row per <name>.json, so a stop that
      // rewrites the record instead of removing it leaves a card no click can
      // clear. Guard the fix: stop deletes the record file (the log stays, so
      // `logs <name>` still works without a record).
      expect(
        kGridServeScript,
        contains('record_path(args.name).unlink(missing_ok=True)'),
      );
    });

    test('a rewrite drops a stale script instead of leaving two copies the '
        'agent could run', () async {
      final dir = Directory('${tmp.path}/skills/grid-serve');
      await Directory('${dir.path}/scripts').create(recursive: true);
      final stale = File('${dir.path}/scripts/old.py');
      await stale.writeAsString('# from an older release');

      await writeSkillFolder(
        dir,
        gridServeSkillFiles(dir, uvPath: '/uv', stateDir: '/svc'),
      );

      expect(stale.existsSync(), isFalse);
      expect(File('${dir.path}/scripts/serve.py').existsSync(), isTrue);
    });
  });
}
