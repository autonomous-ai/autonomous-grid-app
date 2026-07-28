import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/core/grid_paths.dart';
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

    // Read from `$HOME` directly, this came back empty on Windows — a GUI
    // process has no `HOME` — dropping the very directory `grid` installs into.
    test(
      'carries the .local/bin under the resolved home, where grid lives',
      () {
        final dirs = HostEnvironment.path().split(
          Platform.isWindows ? ';' : ':',
        );
        expect(dirs, contains('${GridPaths.userHome}/.local/bin'));
      },
    );
  });

  group('HostEnvironment.gitBashBeside', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('git-root'));
    tearDown(() => root.deleteSync(recursive: true));

    String at(List<String> parts) =>
        [root.path, ...parts].join(Platform.pathSeparator);

    void touch(List<String> parts) =>
        File(at(parts))..createSync(recursive: true);

    test('finds the bash beside a git launched from cmd/', () {
      touch(['cmd', 'git.exe']);
      touch(['bin', 'bash.exe']);
      expect(
        HostEnvironment.gitBashBeside(at(['cmd', 'git.exe'])),
        at(['bin', 'bash.exe']),
      );
    });

    test('finds the same bash for a git launched from bin/', () {
      touch(['bin', 'git.exe']);
      touch(['bin', 'bash.exe']);
      expect(
        HostEnvironment.gitBashBeside(at(['bin', 'git.exe'])),
        at(['bin', 'bash.exe']),
      );
    });

    // A shim or stub with no Git layout around it: no answer beats a guessed
    // path, which would fail exactly like the WSL bash this exists to avoid.
    test('gives no answer when there is no bash beside git', () {
      touch(['cmd', 'git.exe']);
      expect(HostEnvironment.gitBashBeside(at(['cmd', 'git.exe'])), isNull);
    });
  });

  group('HostEnvironment.hermesEnvironment', () {
    test('points Hermes at our Git Bash on Windows, when we found one', () {
      final env = HostEnvironment.hermesEnvironment();
      final bash = HostEnvironment.gitBash();
      if (!Platform.isWindows || bash == null) {
        // Off Windows Hermes finds bash itself; we must not invent the variable.
        if (!Platform.isWindows) {
          expect(env.containsKey('HERMES_GIT_BASH_PATH'), isFalse);
        }
        return;
      }
      expect(env['HERMES_GIT_BASH_PATH'], bash);
      // Never the WSL launcher — the whole point of setting it.
      expect(
        env['HERMES_GIT_BASH_PATH']!.toLowerCase(),
        isNot(contains(r'\system32\')),
      );
    });

    test('always carries the augmented PATH and HERMES_HOME', () {
      final env = HostEnvironment.hermesEnvironment();
      expect(env['PATH'], HostEnvironment.path());
      expect(env['HERMES_HOME'], HostEnvironment.hermesHome);
    });
  });
}
