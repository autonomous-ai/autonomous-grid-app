import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Runs host shell work the `grid` CLI doesn't cover — the Homebrew bootstrap.
///
/// Homebrew's official installer can't be driven from a GUI: it hard-requires an
/// interactive `sudo` (a real tty + typed password), which a Finder-launched app
/// has no way to provide. So instead of installing silently we hand off to
/// Terminal.app, where the user runs the official installer and types their
/// password, then the app re-checks. Behind an interface so the setup controller
/// is testable without spawning `osascript`.
abstract interface class HostShellService {
  /// Opens Terminal.app and runs [command] in a new window, bringing it to the
  /// front. Returns whether the launch itself succeeded — not whether [command]
  /// later succeeds (that happens asynchronously in Terminal).
  Future<bool> openTerminal(String command);
}

/// Real implementation backed by `osascript` driving Terminal.app.
class HostShellServiceImpl implements HostShellService {
  const HostShellServiceImpl();

  @override
  Future<bool> openTerminal(String command) async {
    final escaped = _escapeForAppleScript(command);
    try {
      final result = await Process.run('osascript', [
        '-e', 'tell application "Terminal" to activate',
        '-e', 'tell application "Terminal" to do script "$escaped"',
      ]);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  /// Escapes a shell command for embedding in an AppleScript string literal:
  /// backslashes first, then double quotes.
  static String _escapeForAppleScript(String command) =>
      command.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
}

/// The host shell used across the app. Overridden with a fake in tests.
final hostShellServiceProvider =
    Provider<HostShellService>((ref) => const HostShellServiceImpl());
