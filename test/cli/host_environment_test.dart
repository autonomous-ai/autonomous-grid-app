import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/host_environment.dart';

void main() {
  group('HostEnvironment.path', () {
    test('includes both Homebrew prefixes and system dirs on macOS/Linux', () {
      if (Platform.isWindows) return;
      final path = HostEnvironment.path();
      final dirs = path.split(':');
      // The dirs a Finder-launched GUI PATH typically omits — the reason the CLI
      // can't find brew/docker/cmake. They must be present regardless of the
      // inherited (minimal) PATH.
      expect(dirs, contains('/usr/local/bin')); // Intel Homebrew + many tools
      expect(dirs, contains('/opt/homebrew/bin')); // Apple Silicon Homebrew
      expect(dirs, contains('/usr/bin'));
    });

    test('has no duplicate entries', () {
      final dirs = HostEnvironment.path().split(Platform.isWindows ? ';' : ':');
      expect(dirs.toSet().length, dirs.length);
    });

    test('is cached (stable across calls)', () {
      expect(HostEnvironment.path(), HostEnvironment.path());
    });
  });
}
