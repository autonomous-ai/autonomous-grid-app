import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/terminal/logic/terminal_shell.dart';

void main() {
  test('a terminal opens the shell the account actually uses', () {
    final shell = resolveShell(
      environment: const {'SHELL': '/opt/homebrew/bin/fish'},
      operatingSystem: 'macos',
    );

    expect(shell.executable, '/opt/homebrew/bin/fish');
  });

  test('the shell is a login shell, so the user PATH is the one they have', () {
    // Without this the app's own PATH is all the terminal gets — the bare one
    // launchd hands a Finder-launched app — and Homebrew, nvm and flutter are
    // all missing from a terminal the chat beside it just told them to use.
    for (final os in ['macos', 'linux']) {
      expect(
        resolveShell(environment: const {}, operatingSystem: os).arguments,
        ['-l'],
        reason: '$os should start a login shell',
      );
    }
  });

  test('each platform falls back to its own default shell', () {
    expect(
      resolveShell(environment: const {}, operatingSystem: 'macos').executable,
      '/bin/zsh',
    );
    expect(
      resolveShell(environment: const {}, operatingSystem: 'linux').executable,
      '/bin/bash',
    );
  });

  test('a set-but-empty SHELL falls back rather than spawning nothing', () {
    final shell = resolveShell(
      environment: const {'SHELL': ''},
      operatingSystem: 'macos',
    );

    expect(shell.executable, '/bin/zsh');
  });

  test('Windows takes the command processor, and no login flag', () {
    final shell = resolveShell(
      environment: const {'COMSPEC': r'C:\Windows\System32\cmd.exe'},
      operatingSystem: 'windows',
    );

    expect(shell.executable, r'C:\Windows\System32\cmd.exe');
    expect(shell.arguments, isEmpty);
  });

  test('Windows without COMSPEC still has a shell to open', () {
    expect(
      resolveShell(
        environment: const {},
        operatingSystem: 'windows',
      ).executable,
      'cmd.exe',
    );
  });
}
