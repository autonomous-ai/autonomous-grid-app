import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/chrome_extension_probe.dart';

/// A fake Chrome profile carrying the extension, under a temp home.
void writeExtension(String home, {String profile = 'Default'}) {
  Directory(
    '${chromiumUserDataDirs(home).first}/$profile/Extensions/'
    '$kClaudeInChromeExtensionId/1.0.36_0',
  ).createSync(recursive: true);
}

/// The manifest Claude Code writes the first time it runs with `--chrome`.
void writeHost(String home) {
  final file = File(
    '${chromiumUserDataDirs(home).first}/NativeMessagingHosts/'
    '$kClaudeCodeNativeHost.json',
  )..parent.createSync(recursive: true);
  file.writeAsStringSync('{"name": "$kClaudeCodeNativeHost"}');
}

void main() {
  late Directory home;

  setUp(() => home = Directory.systemTemp.createTempSync('grid_chrome_'));
  tearDown(() => home.deleteSync(recursive: true));

  test('a computer without the extension keeps the browser lane shut, rather '
      'than paying for browser tools nothing answers', () {
    expect(
      ChromeExtensionProbe(userHome: home.path).detect(),
      ChromeExtensionState.missing,
    );
  });

  test('an extension with no host manifest reads as pending, because Chrome '
      'only picks the manifest up when it starts', () {
    writeExtension(home.path);
    expect(
      ChromeExtensionProbe(userHome: home.path).detect(),
      ChromeExtensionState.hostPending,
    );
  });

  test('extension plus manifest is the one state a turn may drive', () {
    writeExtension(home.path);
    writeHost(home.path);
    expect(
      ChromeExtensionProbe(userHome: home.path).detect(),
      ChromeExtensionState.ready,
    );
  });

  test('the extension is found in a secondary profile too — a user can carry '
      'it in "Profile 1" and not in "Default"', () {
    writeExtension(home.path, profile: 'Profile 1');
    writeHost(home.path);
    expect(
      ChromeExtensionProbe(userHome: home.path).detect(),
      ChromeExtensionState.ready,
    );
  });

  test('a host manifest on its own is not enough: no extension means nothing '
      'to talk to', () {
    writeHost(home.path);
    expect(
      ChromeExtensionProbe(userHome: home.path).detect(),
      ChromeExtensionState.missing,
    );
  });
}
