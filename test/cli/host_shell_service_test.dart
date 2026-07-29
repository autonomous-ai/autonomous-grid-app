import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/host_shell_service.dart';

void main() {
  group('HostShellServiceImpl.launchSucceeded', () {
    // explorer.exe exits 1 on success as readily as on failure, so an exit code
    // read literally reported "Couldn't open …" over a window the user could
    // see. On Windows the folder's existence is the only honest signal.
    group('on Windows', () {
      bool opened({required int exitCode, required bool folderExists}) =>
          HostShellServiceImpl.launchSucceeded(
            exitCode: exitCode,
            folderExists: folderExists,
            onWindows: true,
          );

      test('explorer exiting 1 on a real folder still means it opened', () {
        expect(opened(exitCode: 1, folderExists: true), isTrue);
      });

      test('a folder that is not there is the one real failure', () {
        expect(opened(exitCode: 1, folderExists: false), isFalse);
        expect(opened(exitCode: 0, folderExists: false), isFalse);
      });
    });

    group('on macOS and Linux', () {
      bool opened({required int exitCode, required bool folderExists}) =>
          HostShellServiceImpl.launchSucceeded(
            exitCode: exitCode,
            folderExists: folderExists,
            onWindows: false,
          );

      // `open` and `xdg-open` report honestly, so they stay believed — including
      // when they fail on a path that does happen to exist (no file manager, a
      // headless session).
      test('the exit code decides', () {
        expect(opened(exitCode: 0, folderExists: true), isTrue);
        expect(opened(exitCode: 1, folderExists: true), isFalse);
      });
    });
  });
}
