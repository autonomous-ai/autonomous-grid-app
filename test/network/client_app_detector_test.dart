import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/client_app_detector.dart';

const _home = '/home/u';

ClientAppDetector _detector({
  Set<String> dirs = const {},
  Set<String> executables = const {},
}) => ClientAppDetector(
  home: _home,
  dirExists: dirs.contains,
  findExecutable: (name) => executables.contains(name) ? '/bin/$name' : null,
);

void main() {
  test('a present config directory marks the app installed', () {
    final d = _detector(dirs: {'$_home/.hermes'});
    expect(d.isInstalled(ClientApp.hermes), isTrue);
    expect(d.isInstalled(ClientApp.codex), isFalse);
    expect(d.detect(), {ClientApp.hermes});
  });

  test('an app the build hides is never reported as installed', () {
    // OpenClaw on disk must not light up a chip for a tab the picker doesn't
    // draw — isInstalled still answers honestly, detect() is what the UI reads.
    final d = _detector(dirs: {'$_home/.openclaw'});
    expect(d.isInstalled(ClientApp.openClaw), isTrue);
    expect(d.detect(), isEmpty);
  });

  test('an executable on PATH counts even without a config dir', () {
    final d = _detector(executables: {'hermes'});
    expect(d.isInstalled(ClientApp.hermes), isTrue);
    expect(d.detect(), {ClientApp.hermes});
  });

  test('neither signal means not installed', () {
    expect(_detector().detect(), isEmpty);
  });

  test('detect() only reports apps this build offers, in values order', () {
    final d = _detector(
      dirs: {'$_home/.openclaw', '$_home/.hermes', '$_home/.codex'},
    );
    // An installed-but-hidden app (Codex outside debug) must not come back as
    // installed — it would light up a chip the picker doesn't render.
    expect(d.detect().toList(), kSelectableClientApps);
  });

  test('the guide offers Hermes and Codex, never OpenClaw', () {
    // Codex ships to everyone: whether it can answer is the grid's call, per
    // grid (agentRunsOnGridProvider), not something the build decides for all
    // of them. OpenClaw is off the list outright.
    expect(ClientApp.hermes.isSelectable, isTrue);
    expect(ClientApp.codex.isSelectable, isTrue);
    expect(ClientApp.openClaw.isSelectable, isFalse);
    expect(kSelectableClientApps, [ClientApp.hermes, ClientApp.codex]);
  });

  test('the picker always has something to fall back on', () {
    // The guide defaults to kSelectableClientApps.first when the user has none
    // of them installed — hiding the last app would throw there, not degrade.
    expect(kSelectableClientApps, isNotEmpty);
  });

  group('appSetupGuide', () {
    test('Hermes walks the in-app Custom endpoint flow', () {
      final guide = appSetupGuide(kClientApps[ClientApp.hermes]!);
      expect(guide.title, contains('Hermes'));
      final joined = guide.steps.join(' | ');
      // The GUI path, not a config-file edit.
      expect(joined, contains('Custom endpoint'));
      expect(joined, contains('Local / custom endpoint'));
      expect(joined, contains('Connect'));
      // Names the two copyable fields the user pastes.
      expect(joined, contains('Base URL'));
      expect(joined, contains('API key'));
      expect(joined, isNot(contains('config.yaml')));
    });

    test('OpenClaw walks the config-file edit, naming its path', () {
      final info = kClientApps[ClientApp.openClaw]!;
      final guide = appSetupGuide(info);
      final joined = guide.steps.join(' | ');
      expect(joined, contains(info.configPath));
      expect(joined, contains('Restart ${info.name}'));
    });

    test('Codex names both files it needs — the config and the key', () {
      final info = kClientApps[ClientApp.codex]!;
      final guide = appSetupGuide(info);
      final joined = guide.steps.join(' | ');
      expect(joined, contains(info.configPath)); // ~/.codex/config.toml
      expect(joined, contains(kCodexEnvPath)); // …and where the key goes
    });
  });
}
