import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/phone/logic/phone_projects.dart';

/// The name a phone gives a new project becomes a **folder name on somebody's
/// computer**. It is the one string in this feature that crosses the wire and
/// ends up in a path, so what survives the filter is the whole security story.
void main() {
  group('a project name from a phone', () {
    test('keeps what a person would actually type', () {
      expect(safeProjectName('Holiday Site'), 'Holiday Site');
      expect(safeProjectName('me-truyen-chu'), 'me-truyen-chu');
      expect(safeProjectName('grid_2026'), 'grid_2026');
    });

    test('cannot become more than one path segment, which is the only thing '
        'that matters here', () {
      expect(safeProjectName('../../.ssh'), isNot(contains('/')));
      expect(safeProjectName('../../.ssh'), isNot(contains('.')));
      expect(safeProjectName('a/b'), 'ab');
      expect(safeProjectName(r'a\b'), 'ab');
    });

    test('is null for `..`, because both its characters are dropped and '
        'nothing is left — no case of its own needed', () {
      expect(safeProjectName('..'), isNull);
      expect(safeProjectName('.'), isNull);
      expect(safeProjectName('/'), isNull);
    });

    test('is null for a name with nothing usable in it, rather than making a '
        'folder called something nobody asked for', () {
      expect(safeProjectName(''), isNull);
      expect(safeProjectName('   '), isNull);
      expect(safeProjectName('~!@#\$%^&*()'), isNull);
    });

    test('refuses a name too long to read in a sidebar', () {
      expect(safeProjectName('a' * kProjectNameMax), isNotNull);
      expect(safeProjectName('a' * (kProjectNameMax + 1)), isNull);
    });

    test('collapses runs of whitespace, so a stray double space does not make '
        'two folders that look identical', () {
      expect(safeProjectName('two   words'), 'two words');
      expect(safeProjectName('  padded  '), 'padded');
    });

    test('lands under the home folder rather than inside ~/.grid, because the '
        'person opens it in Finder when they get to the computer', () {
      expect(kPhoneProjectsRoot, endsWith('/Grid'));
      expect(kPhoneProjectsRoot, isNot(contains('/.grid')));
    });
  });
}
