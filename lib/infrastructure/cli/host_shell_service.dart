import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Hands a path to the desktop so the user can work with it themselves — the one
/// bit of host shell the `grid` CLI doesn't cover.
///
/// The Projects screen uses it to open the assistant's folder in Finder: putting
/// files where the agent can read them is a drag-and-drop job, and the OS file
/// manager does that far better than anything the app could build. Behind an
/// interface so callers stay testable without spawning a process.
abstract interface class HostShellService {
  /// Reveals [path] in the platform's file manager. Returns whether the launch
  /// succeeded, so the caller can say "couldn't open it" instead of appearing to
  /// do nothing.
  Future<bool> openFolder(String path);
}

/// Real implementation: `open` on macOS, `xdg-open` on Linux, `explorer` on
/// Windows.
class HostShellServiceImpl implements HostShellService {
  const HostShellServiceImpl();

  @override
  Future<bool> openFolder(String path) async {
    final command = switch (Platform.operatingSystem) {
      'macos' => 'open',
      'windows' => 'explorer',
      _ => 'xdg-open',
    };
    try {
      final result = await Process.run(command, [path]);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }
}

/// The host shell used across the app. Overridden with a fake in tests.
final hostShellServiceProvider = Provider<HostShellService>(
  (ref) => const HostShellServiceImpl(),
);
