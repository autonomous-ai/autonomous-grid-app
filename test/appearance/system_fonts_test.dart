import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/platform/system_fonts.dart';

/// Which faces the Typography pickers are allowed to offer, and whether a face
/// the user once chose is still on this Mac.
///
/// Pure on purpose: what the type *looks* like is a question for a screenshot
/// of the running app — the headless font manager resolves every family to one
/// test face, so a rendering assertion here would pass either way.
void main() {
  group('buildFontOptions', () {
    test('curated names come first, then everything else installed', () {
      final options = buildFontOptions(
        curated: const [
          FontChoice(label: 'System', family: null),
          FontChoice(label: 'Menlo', family: 'Menlo'),
        ],
        installed: const ['Arial', 'Menlo', 'Zapfino'],
      );

      expect(options.map((o) => o.label).toList(), [
        'System',
        'Menlo',
        'Arial',
        'Zapfino',
      ]);
    });

    test('a curated face is never listed twice', () {
      final options = buildFontOptions(
        curated: const [FontChoice(label: 'Menlo', family: 'Menlo')],
        installed: const ['Menlo'],
      );
      expect(options.where((o) => o.family == 'Menlo').length, 1);
    });

    test('a curated face this Mac lacks is marked, not dropped', () {
      final options = buildFontOptions(
        curated: const [FontChoice(label: 'Inter', family: 'Inter')],
        installed: const ['Menlo'],
      );
      expect(
        options.firstWhere((o) => o.family == 'Inter').detail,
        'Not installed',
      );
    });

    // With no platform answer at all — a failed channel, or a widget test —
    // the curated list still has to be usable rather than empty.
    test('an empty installed list still yields the curated names', () {
      final options = buildFontOptions(
        curated: kCuratedCodeFonts,
        installed: const [],
      );
      expect(options.length, kCuratedCodeFonts.length);
      expect(options.first.family, isNull, reason: 'System is always offered');
    });
  });

  group('isFamilyInstalled', () {
    test('the system font is always considered present', () {
      expect(isFamilyInstalled(null, const []), isTrue);
    });

    test('a named family is only present when the list says so', () {
      expect(isFamilyInstalled('Menlo', const ['Menlo']), isTrue);
      expect(isFamilyInstalled('Menlo', const ['Arial']), isFalse);
    });
  });
}
