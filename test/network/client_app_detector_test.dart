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
      dirs: {
        '$_home/.openclaw',
        '$_home/.hermes',
        '$_home/.codex',
        '$_home/.claude',
        '$_home/${kClientApps[ClientApp.buzz]!.configDir}',
      },
    );
    // An installed-but-hidden app (OpenClaw, Buzz) must not come back as
    // installed — it would light up a chip the picker doesn't render.
    expect(d.detect().toList(), kSelectableClientApps);
  });

  test('the guide offers Hermes, Codex and Claude Code — never OpenClaw or '
      'Buzz', () {
    // Codex and Claude Code ship to everyone: whether a grid can answer is the
    // grid's call, per grid, not something the build decides for all of them.
    // OpenClaw and Buzz are off the list outright.
    expect(ClientApp.hermes.isSelectable, isTrue);
    expect(ClientApp.codex.isSelectable, isTrue);
    expect(ClientApp.claudeCode.isSelectable, isTrue);
    expect(ClientApp.openClaw.isSelectable, isFalse);
    expect(ClientApp.buzz.isSelectable, isFalse);
    expect(kSelectableClientApps, [
      ClientApp.hermes,
      ClientApp.codex,
      ClientApp.claudeCode,
    ]);
  });

  test('Claude Code is detected by ~/.claude, and says up front what this grid '
      "can't answer for it", () {
    final info = kClientApps[ClientApp.claudeCode]!;
    final d = _detector(dirs: {'$_home/${info.configDir}'});

    expect(d.isInstalled(ClientApp.claudeCode), isTrue);
    // The caveat has to name the API and the symptom, or it reads as vague
    // hedging and the user follows the steps anyway.
    expect(info.caveat, isNotNull);
    expect(info.caveat, contains('/v1/messages'));
    expect(info.caveat, contains('connection error'));
    // Every other offered app talks the dialect the relay already serves.
    expect(kClientApps[ClientApp.hermes]!.caveat, isNull);
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

    test('Claude Code names its settings file and how to check it landed', () {
      final info = kClientApps[ClientApp.claudeCode]!;
      final guide = appSetupGuide(info);
      final joined = guide.steps.join(' | ');

      expect(joined, contains(kClaudeSettingsPath));
      // It reads the file at startup, so a session left open keeps the old
      // connection and the user would call the setup broken.
      expect(guide.steps.first, contains('Quit'));
      // A step the user can act on to see whether it worked.
      expect(joined, contains('/status'));
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
