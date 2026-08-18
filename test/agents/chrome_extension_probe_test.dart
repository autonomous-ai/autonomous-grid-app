import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/chrome_extension_probe.dart';

void main() {
  late Directory home;
  late Directory bridge;

  setUp(() {
    home = Directory.systemTemp.createTempSync('chrome-probe-');
    bridge = Directory('${home.path}/bridge')..createSync();
  });

  tearDown(() => home.deleteSync(recursive: true));

  ChromeExtensionProbe probe() =>
      ChromeExtensionProbe(userHome: home.path, bridgeDir: bridge.path);

  void installExtension() => Directory(
    '${chromiumUserDataDirs(home.path).first}/Default/Extensions/'
    '$kClaudeInChromeExtensionId',
  ).createSync(recursive: true);

  /// What a browser that has connected leaves behind: the native host it
  /// launched listening on a socket named for its own pid.
  void connectBrowser() => File('${bridge.path}/4242.sock').createSync();

  test(
    'a connected browser is what ready means: the app used to call a written '
    'manifest ready and hand the next turn --chrome with nothing behind it, '
    'which reads as an agent that will not open the browser',
    () {
      installExtension();

      expect(probe().detect(), ChromeExtensionState.hostPending);

      connectBrowser();

      expect(probe().detect(), ChromeExtensionState.ready);
    },
  );

  test(
    'a browser holding the bridge open is proof on its own, even when the '
    'extension sits in a browser this app does not know how to look inside',
    () {
      connectBrowser();

      expect(probe().detect(), ChromeExtensionState.ready);
    },
  );

  test('a computer with no extension anywhere is told to install it, not to '
      'restart a browser that would change nothing', () {
    expect(probe().detect(), ChromeExtensionState.missing);
  });

  test('an empty bridge directory is not a connection — a browser that has '
      'never launched the host leaves the folder behind', () {
    installExtension();

    expect(probe().detect(), ChromeExtensionState.hostPending);
  });

  group('naming the bridge directory the way Claude Code does', () {
    test('takes the login name from the environment when it is there', () {
      expect(
        bridgeUserName(
          environment: const {'USER': 'ada'},
          userHome: '/Users/someone-else',
        ),
        'ada',
      );
    });

    test('falls back to the home folder name, because a Grid launched from '
        'Finder gets an environment with no USER in it at all', () {
      expect(
        bridgeUserName(environment: const {}, userHome: '/Users/ada/'),
        'ada',
      );
      expect(
        bridgeUserName(environment: const {'USER': '  '}, userHome: '/'),
        'default',
      );
    });

    test('names the directory the CLI connects to', () {
      expect(claudeBridgeDir('ada'), '/tmp/claude-mcp-browser-bridge-ada');
    });
  });
}
