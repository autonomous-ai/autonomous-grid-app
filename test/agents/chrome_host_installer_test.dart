import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/chrome_extension_probe.dart';
import 'package:grid_app/infrastructure/cli/chrome_host_installer.dart';

void main() {
  late Directory home;
  late File claude;

  setUp(() {
    home = Directory.systemTemp.createTempSync('chrome-host-');
    claude = File('${home.path}/bin/claude')
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\n');
  });

  tearDown(() => home.deleteSync(recursive: true));

  ChromeHostInstaller installerFor(String binary) =>
      ChromeHostInstaller(claudeBinary: binary, userHome: home.path);

  /// The user-data directory of a browser that is actually on this computer.
  String makeBrowser() {
    final dir = chromiumUserDataDirs(home.path).first;
    Directory(dir).createSync(recursive: true);
    return dir;
  }

  String manifestIn(String browserDir) => File(
    '$browserDir/NativeMessagingHosts/$kClaudeCodeNativeHost.json',
  ).readAsStringSync();

  test('a browser that has never seen Claude Code ends the pass carrying the '
      'connection — that is the whole point of doing it at launch, because '
      'nothing else on this machine ever writes it', () async {
    final browser = makeBrowser();

    final install = await installerFor(claude.path).install();

    expect(install.browsers, [browser]);
    expect(install.changed, isTrue);
    expect(manifestIn(browser), contains(kClaudeInChromeExtensionId));
    expect(manifestIn(browser), contains(kClaudeCodeNativeHost));
  });

  test('the manifest points Chrome at a wrapper that exists and may be run — '
      'an unrunnable path is the same as no connection at all', () async {
    final browser = makeBrowser();

    await installerFor(claude.path).install();

    final script = File('${home.path}/$kClaudeHostScriptPath');
    expect(manifestIn(browser), contains(script.path));
    expect(script.existsSync(), isTrue);
    expect(script.readAsStringSync(), contains('exec "${claude.path}"'));
    expect(script.readAsStringSync(), contains(kClaudeNativeHostFlag));
    expect(script.statSync().mode & 0x49, 0x49, reason: 'executable by all');
  });

  test('browsers this computer does not have are left alone: writing a '
      'manifest folder for Brave would invent a browser the user never '
      'installed', () async {
    final browser = makeBrowser();
    final absent = chromiumUserDataDirs(home.path).last;

    final install = await installerFor(claude.path).install();

    expect(install.browsers, [browser]);
    expect(Directory(absent).existsSync(), isFalse);
  });

  test('a second launch writes nothing and says so, so the card does not ask '
      'for a Chrome restart every single time the app opens', () async {
    makeBrowser();
    final installer = installerFor(claude.path);

    await installer.install();
    final second = await installer.install();

    expect(second.changed, isFalse);
  });

  test('a machine Claude Code already set up is left untouched: the manifest '
      'is written to the byte Claude Code writes, so being second changes '
      'nothing and asks for no restart', () async {
    final browser = makeBrowser();
    final script = '${home.path}/$kClaudeHostScriptPath';
    File(script)
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '#!/bin/sh\nexec "${claude.path}" '
        '$kClaudeNativeHostFlag\n',
      );
    // What `claude --chrome` leaves behind — no trailing newline.
    File('$browser/NativeMessagingHosts/$kClaudeCodeNativeHost.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(claudeChromeHostManifest(hostPath: script));

    final install = await installerFor(claude.path).install();

    expect(install.changed, isFalse);
  });

  test('a wrapper left pointing at a Claude Code that has been updated away is '
      'rewritten: Claude Code names the versioned file it is running from, so '
      'its own updates silently break the browser', () async {
    makeBrowser();
    final script = File('${home.path}/$kClaudeHostScriptPath')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        claudeChromeHostScript(claudeBinary: '${home.path}/versions/2.1.181'),
      );

    await installerFor(claude.path).install();

    expect(script.readAsStringSync(), contains('exec "${claude.path}"'));
  });

  test('a wrapper that still points at a Claude Code that is there is left '
      'exactly as it was — the file says "do not edit manually", and a good '
      'one is not ours to churn', () async {
    makeBrowser();
    final script = File('${home.path}/$kClaudeHostScriptPath')
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\nexec "${claude.path}" --chrome-x\n');

    await installerFor(claude.path).install();

    expect(script.readAsStringSync(), contains('--chrome-x'));
  });

  group('reading the binary out of a wrapper', () {
    test('finds the quoted path Claude Code writes', () {
      expect(
        claudeHostScriptTarget(
          '#!/bin/sh\n# Generated by Claude Code\n'
          'exec "/Users/x/.local/share/claude/versions/2.1.183" '
          '--chrome-native-host\n',
        ),
        '/Users/x/.local/share/claude/versions/2.1.183',
      );
    });

    test('answers null for a script that names nothing, so a file this app '
        'cannot read is replaced rather than trusted', () {
      expect(claudeHostScriptTarget('#!/bin/sh\necho hello\n'), isNull);
      expect(
        claudeHostScriptTarget('exec claude --chrome-native-host'),
        isNull,
      );
    });
  });
}
