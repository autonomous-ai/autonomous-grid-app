import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/adapters/claude_tool.dart';
import 'package:grid_app/features/agents/logic/chrome_setup_controller.dart';
import 'package:grid_app/infrastructure/cli/chrome_extension_probe.dart';
import 'package:grid_app/infrastructure/cli/chrome_host_installer.dart';

void main() {
  late Directory home;
  late File claude;

  setUp(() {
    home = Directory.systemTemp.createTempSync('chrome-connect-');
    claude = File('${home.path}/bin/claude')
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\n');
  });

  tearDown(() => home.deleteSync(recursive: true));

  /// A Chrome on disk, so there is something to connect to.
  String makeBrowser() {
    final dir = chromiumUserDataDirs(home.path).first;
    Directory(dir).createSync(recursive: true);
    return dir;
  }

  ProviderContainer containerWith({required bool claudeInstalled}) =>
      ProviderContainer(
        overrides: [
          claudePathProvider.overrideWithValue(
            claudeInstalled ? claude.path : null,
          ),
          chromeHostInstallerProvider.overrideWith(
            (ref) => ref.watch(claudePathProvider) == null
                ? null
                : ChromeHostInstaller(
                    claudeBinary: claude.path,
                    userHome: home.path,
                  ),
          ),
          chromeExtensionProbeProvider.overrideWithValue(
            ChromeExtensionProbe(userHome: home.path),
          ),
        ],
      );

  bool connectionLandedIn(String browser) => File(
    '$browser/NativeMessagingHosts/$kClaudeCodeNativeHost.json',
  ).existsSync();

  test('the launch pass connects Chrome without saying a word: it costs a file '
      'write, so it happens for everybody, and a user who never asked for a '
      'browser is not shown a setup message about one', () async {
    final browser = makeBrowser();
    final container = containerWith(claudeInstalled: true);
    addTearDown(container.dispose);

    await container.read(chromeSetupProvider.notifier).connect(announce: false);

    expect(connectionLandedIn(browser), isTrue);
    expect(container.read(chromeSetupProvider), isA<ChromeSetupIdle>());
  });

  test('pressing the button says what happened, because a press with no answer '
      'reads as a button that does nothing', () async {
    makeBrowser();
    final container = containerWith(claudeInstalled: true);
    addTearDown(container.dispose);

    await container.read(chromeSetupProvider.notifier).connect();

    expect(container.read(chromeSetupProvider), isA<ChromeSetupDone>());
  });

  test('with no Chrome on the computer the button says so rather than claiming '
      'a connection to a browser that is not there', () async {
    final container = containerWith(claudeInstalled: true);
    addTearDown(container.dispose);

    await container.read(chromeSetupProvider.notifier).connect();

    final state = container.read(chromeSetupProvider);
    expect(state, isA<ChromeSetupFailed>());
    expect((state as ChromeSetupFailed).message, contains('no Chrome'));
  });

  test('with Claude Code missing altogether there is nothing to connect, and '
      'the launch pass leaves no failure on a card nobody opened', () async {
    final container = containerWith(claudeInstalled: false);
    addTearDown(container.dispose);

    await container.read(chromeSetupProvider.notifier).connect(announce: false);
    expect(container.read(chromeSetupProvider), isA<ChromeSetupIdle>());

    await container.read(chromeSetupProvider.notifier).connect();
    expect(container.read(chromeSetupProvider), isA<ChromeSetupFailed>());
  });
}
