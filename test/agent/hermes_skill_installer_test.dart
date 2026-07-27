import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/hermes/hermes_skill_installer.dart';

void main() {
  late Directory home;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('grid_skill_test');
  });
  tearDown(() => home.delete(recursive: true));

  File script(String skill) =>
      File('${home.path}/.hermes/skills/grid/$skill/scripts/generate.py');
  File skillMd(String skill) =>
      File('${home.path}/.hermes/skills/grid/$skill/SKILL.md');

  test('installs both the image and video skill files', () async {
    await HermesSkillInstaller(home: home.path).install();

    for (final skill in const ['grid-image-gen', 'grid-video-gen']) {
      expect(skillMd(skill).existsSync(), isTrue, reason: '$skill SKILL.md');
      expect(script(skill).existsSync(), isTrue, reason: '$skill script');
      expect(skillMd(skill).readAsStringSync(), contains(skill));
    }
  });

  test('neither script bakes credentials or a grid — both read them at run '
      'time from the same OPENAI_* pair', () async {
    await HermesSkillInstaller(home: home.path).install();

    for (final skill in const ['grid-image-gen', 'grid-video-gen']) {
      final source = script(skill).readAsStringSync();
      // No JWT, no hardcoded grid host — the prototype's leak must not recur.
      expect(source, isNot(contains('eyJ')), reason: '$skill has a baked JWT');
      expect(
        source,
        isNot(contains('grid.autonomous.ai')),
        reason: '$skill hardcodes a grid',
      );
      // Both source the endpoint + key from the environment / ~/.hermes/.env,
      // and from the SAME variables — so switching grids repoints both at once.
      expect(source, contains('OPENAI_BASE_URL'));
      expect(source, contains('OPENAI_API_KEY'));
      expect(source, contains('.hermes/.env'));
    }
  });

  test('the video skill does not read GRID_API_KEY and targets the i2v '
      'endpoint — the exact bug the prototype had', () async {
    await HermesSkillInstaller(home: home.path).install();
    final source = script('grid-video-gen').readAsStringSync();

    expect(
      source,
      isNot(contains('GRID_API_KEY')),
      reason: 'video must use OPENAI_API_KEY, not the stale GRID_API_KEY',
    );
    expect(source, contains('/media/video/i2v'));
  });

  test(
    'overwrites a leaked video prototype in place, clearing its stale files',
    () async {
      // The hand-made prototype: a hardcoded grid + GRID_API_KEY, plus a
      // references/ dir the clean skill doesn't have.
      final proto = Directory(
        '${home.path}/.hermes/skills/grid/grid-video-gen',
      );
      await Directory('${proto.path}/references').create(recursive: true);
      await File('${proto.path}/references/api-details.md').writeAsString(
        'Base URL: https://grid.autonomous.ai/grid-1ffe6152a2e547fa/relay/v1\n'
        'API Key: GRID_API_KEY',
      );
      await Directory('${proto.path}/scripts').create(recursive: true);
      await File('${proto.path}/scripts/generate.py').writeAsString(
        'BASE_URL = "https://grid.autonomous.ai/grid-1ffe6152a2e547fa/relay/v1"',
      );

      await HermesSkillInstaller(home: home.path).install();

      // The clean script replaced it — no hardcoded grid left anywhere.
      expect(
        script('grid-video-gen').readAsStringSync(),
        isNot(contains('grid-1ffe6152a2e547fa')),
      );
      // The stale references/ dir is gone (wiped before the fresh write).
      expect(
        Directory('${proto.path}/references').existsSync(),
        isFalse,
        reason: 'stale prototype files must not linger',
      );
    },
  );

  test(
    'removes leaked prototypes under the creative/ and skills root',
    () async {
      for (final leaked in const [
        '.hermes/skills/creative/grid-image-gen',
        '.hermes/skills/grid-video-gen',
      ]) {
        final dir = Directory('${home.path}/$leaked/scripts');
        await dir.create(recursive: true);
        await File(
          '${dir.path}/generate.py',
        ).writeAsString('API_KEY = "eyJleak"');
      }

      await HermesSkillInstaller(home: home.path).install();

      for (final leaked in const [
        '.hermes/skills/creative/grid-image-gen',
        '.hermes/skills/grid-video-gen',
      ]) {
        expect(
          Directory('${home.path}/$leaked').existsSync(),
          isFalse,
          reason: '$leaked must be gone',
        );
      }
      expect(script('grid-image-gen').existsSync(), isTrue);
    },
  );

  test('is idempotent — a second install keeps both skills', () async {
    final installer = HermesSkillInstaller(home: home.path);
    await installer.install();
    await installer.install();

    expect(script('grid-image-gen').existsSync(), isTrue);
    expect(script('grid-video-gen').existsSync(), isTrue);
  });
}
