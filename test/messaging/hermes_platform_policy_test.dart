import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/hermes_platform_policy.dart';
import 'package:grid_app/infrastructure/cli/hermes_task_policy.dart';
import 'package:yaml_edit/yaml_edit.dart';

void main() {
  late Directory tmp;
  late File config;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_platform_policy_test');
    config = File('${tmp.path}/.hermes/config.yaml');
  });
  tearDown(() => tmp.delete(recursive: true));

  HermesPlatformPolicy policy() => HermesPlatformPolicy(home: tmp.path);

  /// What Hermes's config actually says at [path] — null when it says nothing.
  Object? at(List<Object> path) => YamlEditor(
    config.readAsStringSync(),
  ).parseAt(path, orElse: () => wrapAsYamlNode(null)).value;

  test('restrict takes the command tools away from a remote message, rather '
      'than trusting a bot on the internet not to use them', () async {
    await policy().restrict('discord');

    final discord = at(['platform_toolsets', 'discord']) as List;
    expect(discord, isNot(contains('terminal')));
    expect(discord, isNot(contains('code_execution')));
    expect(discord, isNot(contains('computer_use')));
    // It can still read (and, unavoidably, edit) the project's files — answering
    // about them is the whole point, and Hermes has no read-only half.
    expect(discord, contains('file'));
  });

  test('a restricted bot can still reach the web — the browser is how it does '
      'that when no search key is configured', () async {
    await policy().restrict('discord');

    // `web` alone is not enough: web_search / web_extract only load when a
    // search backend has credentials, which a stock install has none of.
    expect(at(['platform_toolsets', 'discord']), contains('browser'));
  });

  test('a bot connected before the limit existed reads as unrestricted, and '
      'restricting flips it', () async {
    expect(await policy().isRestricted('telegram'), isFalse);

    await policy().restrict('telegram');
    expect(await policy().isRestricted('telegram'), isTrue);
  });

  test("Hermes's default (a config that never mentions the platform) is not "
      'restricted — the tools are all there', () async {
    await config.parent.create(recursive: true);
    await config.writeAsString('model:\n  default: qwen\n');
    expect(await policy().isRestricted('slack'), isFalse);
  });

  test('each platform is pinned on its own — restricting Slack does not touch '
      'Telegram', () async {
    await policy().restrict('slack');

    expect(await policy().isRestricted('slack'), isTrue);
    expect(await policy().isRestricted('telegram'), isFalse);
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

    await policy().restrict('telegram');

    expect(at(['model', 'default']), 'qwen');
    expect(at(['approvals', 'mode']), 'smart');
    expect(File('${config.path}.bak').existsSync(), isTrue);
  });

  test('restricting is idempotent — a second call keeps a valid, terminal-free '
      'list rather than corrupting it', () async {
    final p = policy();
    await p.restrict('telegram');
    await p.restrict('telegram');

    final telegram = at(['platform_toolsets', 'telegram']) as List;
    expect(telegram, contains('file'));
    expect(telegram, isNot(contains('terminal')));
    expect(await p.isRestricted('telegram'), isTrue);
  });

  test('the platform limit and the scheduler limit share one config without '
      'stepping on each other', () async {
    await HermesTaskPolicy(home: tmp.path).write(TaskPower.noCommands);
    await policy().restrict('telegram');

    // Both corners are pinned; neither write blew the other away.
    expect(at(['platform_toolsets', 'cron']), isNotNull);
    expect(at(['platform_toolsets', 'telegram']), isNotNull);
    expect(at(['approvals', 'cron_mode']), 'deny');
    expect(await policy().isRestricted('telegram'), isTrue);
  });
}
