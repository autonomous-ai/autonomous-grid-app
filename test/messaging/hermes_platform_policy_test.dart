import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/hermes_config_file.dart';
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

  /// Write a config whose [platform] carries this app's old read-and-answer pin.
  Future<void> writePinned(String platform, {String extra = ''}) async {
    await config.parent.create(recursive: true);
    final list = kReadAndAnswerToolsets.map((t) => '    - $t\n').join();
    await config.writeAsString('platform_toolsets:\n  $platform:\n$list$extra');
  }

  /// What Hermes's config actually says at [path] — null when it says nothing.
  Object? at(List<Object> path) => YamlEditor(
    config.readAsStringSync(),
  ).parseAt(path, orElse: () => wrapAsYamlNode(null)).value;

  test('an old pin is dropped so the platform gets the tools Hermes loads, '
      'the same ones the in-app chat has', () async {
    await writePinned('telegram');
    expect(await policy().isPinned('telegram'), isTrue);

    await policy().unpin('telegram');

    // Removed outright rather than rewritten with a longer list: Hermes never
    // re-seeds a key that exists, so leaving one behind would pin the platform
    // to whatever the app happened to type instead of Hermes's own default.
    expect(at(['platform_toolsets', 'telegram']), isNull);
    expect(await policy().isPinned('telegram'), isFalse);
  });

  test('a list the user wrote themselves is left alone — undoing our own '
      'change must not become editing theirs', () async {
    await config.parent.create(recursive: true);
    await config.writeAsString(
      'platform_toolsets:\n  slack:\n    - file\n    - web\n',
    );

    await policy().unpin('slack');

    expect(at(['platform_toolsets', 'slack']), ['file', 'web']);
  });

  test("Hermes's own seed for a platform survives", () async {
    // `hermes-telegram` and friends are Hermes's defaults, not our pin; removing
    // one would take the platform's own tools away.
    await config.parent.create(recursive: true);
    await config.writeAsString(
      'platform_toolsets:\n  discord:\n    - hermes-discord\n',
    );

    await policy().unpin('discord');

    expect(at(['platform_toolsets', 'discord']), ['hermes-discord']);
  });

  test('a config that never mentioned the platform needs no repair', () async {
    await config.parent.create(recursive: true);
    await config.writeAsString('model:\n  default: qwen\n');

    expect(await policy().isPinned('slack'), isFalse);
    await policy().unpin('slack');

    // Nothing to undo, so nothing is written — not even a backup.
    expect(File('${config.path}.bak').existsSync(), isFalse);
  });

  test('each platform is undone on its own — clearing Slack leaves Telegram '
      'as it was', () async {
    await writePinned('slack', extra: '  telegram:\n    - hermes-telegram\n');

    await policy().unpin('slack');

    expect(at(['platform_toolsets', 'slack']), isNull);
    expect(at(['platform_toolsets', 'telegram']), ['hermes-telegram']);
  });

  test("the user's other settings survive the write, and the old file is kept "
      'as a backup', () async {
    await writePinned(
      'telegram',
      extra: 'model:\n  default: qwen\napprovals:\n  mode: smart\n',
    );

    await policy().unpin('telegram');

    expect(at(['model', 'default']), 'qwen');
    expect(at(['approvals', 'mode']), 'smart');
    expect(File('${config.path}.bak').existsSync(), isTrue);
  });

  test(
    'undoing is idempotent — a second call is a no-op, not a corruption',
    () async {
      await writePinned('telegram');
      final p = policy();
      await p.unpin('telegram');
      await p.unpin('telegram');

      expect(at(['platform_toolsets', 'telegram']), isNull);
    },
  );

  test('the scheduler keeps its own limit when a platform is unpinned — the '
      'two corners of the config never step on each other', () async {
    await writePinned('telegram');
    await HermesTaskPolicy(home: tmp.path).write(TaskPower.noCommands);

    await policy().unpin('telegram');

    // A scheduled task still runs unattended, so its limit is untouched.
    expect(at(['platform_toolsets', 'cron']), isNotNull);
    expect(at(['approvals', 'cron_mode']), 'deny');
  });
}
