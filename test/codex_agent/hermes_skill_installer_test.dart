import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/codex_agent/logic/hermes_skill_installer.dart';

void main() {
  late Directory home;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('grid_skill_test');
  });
  tearDown(() => home.delete(recursive: true));

  File script() => File(
    '${home.path}/.hermes/skills/grid/grid-image-gen/scripts/generate.py',
  );
  File skillMd() =>
      File('${home.path}/.hermes/skills/grid/grid-image-gen/SKILL.md');

  test('installs the skill files', () async {
    await HermesSkillInstaller(home: home.path).install();

    expect(skillMd().existsSync(), isTrue);
    expect(script().existsSync(), isTrue);
    expect(skillMd().readAsStringSync(), contains('grid-image-gen'));
  });

  test('the script bakes no credentials — it reads them at run time', () async {
    await HermesSkillInstaller(home: home.path).install();
    final source = script().readAsStringSync();

    // No JWT, no hardcoded grid host — the prototype's leak must not recur.
    expect(source, isNot(contains('eyJ')));
    expect(source, isNot(contains('grid.autonomous.ai')));
    expect(source, isNot(contains('Bearer eyJ')));
    // It sources the endpoint + key from the environment / ~/.hermes/.env.
    expect(source, contains('OPENAI_BASE_URL'));
    expect(source, contains('OPENAI_API_KEY'));
    expect(source, contains('.hermes/.env'));
  });

  test('removes the leaked prototype (baked-key skill)', () async {
    // Simulate the hand-made prototype with a baked key under Hermes's category.
    final leaked = Directory(
      '${home.path}/.hermes/skills/creative/grid-image-gen/scripts',
    );
    await leaked.create(recursive: true);
    await File('${leaked.path}/generate.py').writeAsString('API_KEY = "eyJleaked"');

    await HermesSkillInstaller(home: home.path).install();

    expect(
      Directory('${home.path}/.hermes/skills/creative/grid-image-gen').existsSync(),
      isFalse,
      reason: 'the leaked credential must be gone',
    );
    expect(script().existsSync(), isTrue, reason: 'the clean skill replaces it');
  });

  test('is idempotent — a second install is a no-op that keeps the files',
      () async {
    final installer = HermesSkillInstaller(home: home.path);
    await installer.install();
    await installer.install();

    expect(script().existsSync(), isTrue);
  });
}
