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

  test('OpenClaw on disk is detected, now that the guide offers it', () {
    // OpenClaw is a selectable client again, so a config dir on disk lights up
    // its chip like any other app's.
    final d = _detector(dirs: {'$_home/.openclaw'});
    expect(d.isInstalled(ClientApp.openClaw), isTrue);
    expect(d.detect(), {ClientApp.openClaw});
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
      dirs: {
        '$_home/.openclaw',
        '$_home/.hermes',
        '$_home/.codex',
        '$_home/${kClientApps[ClientApp.buzz]!.configDir}',
      },
    );
    // detect() walks kSelectableClientApps, so it comes back in that tab order.
    expect(d.detect().toList(), kSelectableClientApps);
  });

  test('the guide offers every client, Hermes first then OpenClaw', () {
    // All four ship to everyone: whether a given grid can answer is the grid's
    // call, per grid, not something the build decides for all of them. The list
    // is the tab order the picker draws.
    expect(ClientApp.hermes.isSelectable, isTrue);
    expect(ClientApp.openClaw.isSelectable, isTrue);
    expect(ClientApp.codex.isSelectable, isTrue);
    expect(ClientApp.buzz.isSelectable, isTrue);
    expect(kSelectableClientApps, [
      ClientApp.hermes,
      ClientApp.openClaw,
      ClientApp.codex,
      ClientApp.buzz,
    ]);
  });

  test('Buzz is detected by its app-support dir under home', () {
    final d = _detector(
      dirs: {'$_home/${kClientApps[ClientApp.buzz]!.configDir}'},
    );
    expect(d.isInstalled(ClientApp.buzz), isTrue);
    expect(d.detect(), {ClientApp.buzz});
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

    test('Buzz names its config file and leads with quitting the app', () {
      final info = kClientApps[ClientApp.buzz]!;
      final guide = appSetupGuide(info);
      final joined = guide.steps.join(' | ');
      expect(joined, contains(info.configPath)); // the global-agent-config path
      // The running desktop rewrites the file, so the paste path must quit it
      // first — otherwise the edit is clobbered.
      expect(guide.steps.first, contains('Quit'));
    });
  });
}
