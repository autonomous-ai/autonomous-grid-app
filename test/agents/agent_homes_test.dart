import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/core/agent_homes.dart';

void main() {
  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('grid_agent_homes');
  });
  tearDown(() => home.delete(recursive: true));

  String root() => AgentHomes.hermesRoot(home.path);
  String profile() => AgentHomes.hermesProfile(home.path);

  test('Grid gets a profile beside the user\'s Hermes, never on top of it — '
      'the root is what every `hermes` they run themselves reads', () {
    expect(profile(), '${root()}/profiles/grid');
  });

  test('the profile is created on demand, so a machine that has never run '
      'Hermes still gets one before the first spawn', () async {
    await ensureGridHermesProfile(home.path);

    expect(Directory(profile()).existsSync(), isTrue);
  });

  test('files a running daemon already holds are reached by link, not by copy '
      '— two copies of a cron job means the same task fires twice', () async {
    await Directory(root()).create(recursive: true);
    await File('${root()}/.env').writeAsString('TOKEN=1\n');
    await Directory('${root()}/cron').create();

    await ensureGridHermesProfile(home.path);

    expect(
      FileSystemEntity.typeSync('${profile()}/.env', followLinks: false),
      FileSystemEntityType.link,
    );
    expect(File('${profile()}/.env').readAsStringSync(), 'TOKEN=1\n');
    expect(
      FileSystemEntity.typeSync('${profile()}/cron', followLinks: false),
      FileSystemEntityType.link,
    );
  });

  test('a shared file the root does not have yet is left alone — linking to '
      'nothing would send the first write somewhere nobody reads', () async {
    await ensureGridHermesProfile(home.path);

    expect(File('${profile()}/gateway_state.json').existsSync(), isFalse);
  });

  test(
    'a real file where the link should be is reported, not silently kept — '
    'something wrote through and the two homes have been diverging since',
    () async {
      await Directory(root()).create(recursive: true);
      await File('${root()}/.env').writeAsString('TOKEN=root\n');
      await Directory(profile()).create(recursive: true);
      await File('${profile()}/.env').writeAsString('TOKEN=stale\n');

      final said = <String>[];
      await ensureGridHermesProfile(home.path, log: said.add);

      expect(said.single, contains('.env'));
      expect(File('${profile()}/.env').readAsStringSync(), 'TOKEN=stale\n');
    },
  );

  test(
    'running it twice changes nothing — it is re-run on every launch',
    () async {
      await Directory(root()).create(recursive: true);
      await File('${root()}/.env').writeAsString('TOKEN=1\n');

      await ensureGridHermesProfile(home.path);
      final said = <String>[];
      await ensureGridHermesProfile(home.path, log: said.add);

      expect(said, isEmpty);
      expect(
        FileSystemEntity.typeSync('${profile()}/.env', followLinks: false),
        FileSystemEntityType.link,
      );
    },
  );

  test('a new profile starts from the config the root already had, so the move '
      'is invisible — an empty home means "no model configured" on a machine '
      'that worked yesterday', () async {
    await Directory(root()).create(recursive: true);
    await File('${root()}/config.yaml').writeAsString('model: m1\n');

    await ensureGridHermesProfile(home.path);

    expect(File('${profile()}/config.yaml').readAsStringSync(), 'model: m1\n');
  });

  test('and never again — a second copy would undo whatever the app has since '
      'written to the profile', () async {
    await Directory(root()).create(recursive: true);
    await File('${root()}/config.yaml').writeAsString('model: root\n');
    await ensureGridHermesProfile(home.path);
    await File('${profile()}/config.yaml').writeAsString('model: mine\n');

    await ensureGridHermesProfile(home.path);

    expect(
      File('${profile()}/config.yaml').readAsStringSync(),
      'model: mine\n',
    );
  });
}
