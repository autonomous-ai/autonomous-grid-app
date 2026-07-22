import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/hermes_task_policy.dart';
import 'package:yaml_edit/yaml_edit.dart';

void main() {
  late Directory tmp;
  late File config;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_task_policy_test');
    config = File('${tmp.path}/.hermes/config.yaml');
  });
  tearDown(() => tmp.delete(recursive: true));

  HermesTaskPolicy policy() => HermesTaskPolicy(home: tmp.path);

  /// What Hermes's config actually says at [path] — null when it says nothing.
  Object? at(List<Object> path) => YamlEditor(
    config.readAsStringSync(),
  ).parseAt(path, orElse: () => wrapAsYamlNode(null)).value;

  test('"no commands" takes the command tools away, rather than trusting the '
      'agent not to use them', () async {
    await policy().write(TaskPower.noCommands);

    final cron = at(['platform_toolsets', 'cron']) as List;
    expect(cron, isNot(contains('terminal')));
    expect(cron, isNot(contains('code_execution')));
    // It can still read (and, unavoidably, write) the project's files — looking
    // at them is the whole point of a task.
    expect(cron, contains('file'));
    // And it can still reach the web: a "read me today's news" task has nothing
    // to read without the browser, because web_search / web_extract only load
    // when a search backend has credentials.
    expect(cron, contains('browser'));
    // And a tool that arrives some other way still can't run a dangerous
    // command.
    expect(at(['approvals', 'cron_mode']), 'deny');
  });

  test('full access says so in Hermes\'s own config — the screen is not just '
      'claiming it', () async {
    await policy().write(TaskPower.fullAccess);

    expect(at(['approvals', 'cron_mode']), 'approve');
    // No toolset allowlist: Hermes loads its own defaults, commands included.
    expect(at(['platform_toolsets', 'cron']), isNull);
  });

  test('the user\'s other settings survive the write, and the old file is kept '
      'as a backup', () async {
    await config.parent.create(recursive: true);
    await config.writeAsString('''
model:
  provider: custom
  default: qwen
approvals:
  mode: smart
''');

    await policy().write(TaskPower.noCommands);

    expect(at(['model', 'default']), 'qwen');
    expect(
      at(['approvals', 'mode']),
      'smart',
      reason: 'what the chat does is not this setting\'s business',
    );
    expect(at(['approvals', 'cron_mode']), 'deny');
    expect(File('${config.path}.bak').existsSync(), isTrue);
  });

  test(
    'switching back to full access drops the limit it had written',
    () async {
      final p = policy();
      await p.write(TaskPower.noCommands);
      await p.write(TaskPower.fullAccess);

      expect(at(['platform_toolsets', 'cron']), isNull);
      expect(await p.read(), TaskPower.fullAccess);
    },
  );

  group('read', () {
    test('reflects what the config really says, both ways', () async {
      final p = policy();
      await p.write(TaskPower.noCommands);
      expect(await p.read(), TaskPower.noCommands);

      await p.write(TaskPower.fullAccess);
      expect(await p.read(), TaskPower.fullAccess);
    });

    test('a config that never mentions it is full access — the tools are all '
        'there, and saying otherwise would be a comfortable lie', () async {
      expect(await policy().read(), TaskPower.fullAccess);

      await config.parent.create(recursive: true);
      await config.writeAsString('model:\n  default: qwen\n');
      expect(await policy().read(), TaskPower.fullAccess);
    });
  });
}
