import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/git_probe.dart';

void main() {
  group('whether a Git can carry the grid credential', () {
    test('a Git that announces authtype can', () {
      // Measured on git 2.50.1 (Apple Git-155), which is what
      // `git credential capability` prints on a build that supports it.
      expect(
        reportsAuthtype('version 0\ncapability authtype\ncapability state\n'),
        isTrue,
      );
    });

    test('a Git with the subcommand but no authtype cannot', () {
      // `state` alone is not enough: `authtype` is the only field a helper can
      // name a scheme with, and without it git falls back to Basic — which the
      // relay refuses, so the clone fails after writing a directory.
      expect(reportsAuthtype('version 0\ncapability state\n'), isFalse);
    });

    test('an old Git printing its usage line reads as no, not as unknown', () {
      // git 2.33 has no `credential capability` subcommand at all — measured on
      // the 2021 build an old macOS installer leaves in /usr/local. This is the
      // case the whole check exists for, so it must not be mistaken for a yes.
      expect(
        reportsAuthtype('usage: git credential [fill|approve|reject]'),
        isFalse,
      );
      expect(reportsAuthtype(''), isFalse);
    });

    test('the capability is matched as a whole line, not as a substring', () {
      // A line mentioning authtype in passing is not an announcement of it;
      // reading one as a yes would let a clone start that can never finish.
      expect(reportsAuthtype('capability authtype-ish'), isFalse);
      expect(reportsAuthtype('# capability authtype'), isFalse);
      // Surrounding whitespace is still an announcement.
      expect(reportsAuthtype('version 0\n  capability authtype  \n'), isTrue);
    });
  });
}
