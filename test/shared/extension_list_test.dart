import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:grid_app/shared/widgets/extension_list.dart';

void main() {
  group('sectionExtensionItems', () {
    test(
      'groups into sections with leading order first, rest alphabetical',
      () {
        final sections = sectionExtensionItems(
          items: ['zeta:1', 'mine:2', 'alpha:3', 'mine:4'],
          sectionOf: (s) => s.split(':').first,
          leading: const ['mine'],
          filtered: false,
        );
        expect(sections.map((s) => s.label), ['mine', 'alpha', 'zeta']);
        expect(sections.first.items, ['mine:2', 'mine:4']);
      },
    );

    test('leading entries keep their given order', () {
      final sections = sectionExtensionItems(
        items: ['off:a', 'on:b'],
        sectionOf: (s) => s.startsWith('on') ? 'On' : 'Available',
        leading: const ['On', 'Available'],
        filtered: false,
      );
      // Alphabetically 'Available' < 'On'; the leading list must win.
      expect(sections.map((s) => s.label), ['On', 'Available']);
    });

    test('filtering flattens to a single unlabelled section', () {
      final sections = sectionExtensionItems(
        items: ['a:1', 'b:2'],
        sectionOf: (s) => s.split(':').first,
        filtered: true,
      );
      expect(sections, hasLength(1));
      expect(sections.single.label, '');
      expect(sections.single.items, ['a:1', 'b:2']);
      expect(sectionsShowHeaders(sections), isFalse);
    });

    test('a single populated section renders flat, not under one header', () {
      final sections = sectionExtensionItems(
        items: ['same:1', 'same:2'],
        sectionOf: (s) => s.split(':').first,
        filtered: false,
      );
      expect(sections.single.label, '');
      expect(sectionsShowHeaders(sections), isFalse);
    });

    test('two populated sections show headers', () {
      final sections = sectionExtensionItems(
        items: ['a:1', 'b:2'],
        sectionOf: (s) => s.split(':').first,
        filtered: false,
      );
      expect(sectionsShowHeaders(sections), isTrue);
    });

    test('items keep their incoming order inside a section', () {
      final sections = sectionExtensionItems(
        items: ['g:c', 'g:a', 'h:x', 'g:b'],
        sectionOf: (s) => s.split(':').first,
        filtered: false,
      );
      expect(sections.first.items, ['g:c', 'g:a', 'g:b']);
    });
  });

  group('ExtensionList', () {
    Future<void> pump(WidgetTester tester, List<ExtensionSection<String>> s) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ExtensionList<String>(
              sections: s,
              rowBuilder: (context, item) =>
                  SizedBox(height: 40, child: Text(item)),
            ),
          ),
        ),
      );
    }

    testWidgets('renders headers with counts and all rows', (tester) async {
      await pump(tester, const [
        ExtensionSection(label: 'On', items: ['alpha', 'beta']),
        ExtensionSection(label: 'Available', items: ['gamma']),
      ]);
      expect(find.text('ON'), findsOneWidget);
      expect(find.text('AVAILABLE'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      for (final row in ['alpha', 'beta', 'gamma']) {
        expect(find.text(row), findsOneWidget);
      }
    });

    testWidgets('an unlabelled section draws no header', (tester) async {
      await pump(tester, const [
        ExtensionSection(label: '', items: ['alpha', 'beta']),
      ]);
      // Nothing but the two rows: no uppercase header, no count.
      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('beta'), findsOneWidget);
      expect(find.text('2'), findsNothing);
    });

    testWidgets('rows sit 8px apart; a header gets 18px of air above', (
      tester,
    ) async {
      await pump(tester, const [
        ExtensionSection(label: 'On', items: ['alpha', 'beta']),
        ExtensionSection(label: 'Available', items: ['gamma']),
      ]);
      final alpha = tester.getRect(find.text('alpha'));
      final beta = tester.getRect(find.text('beta'));
      // Rows are fixed 40px tall, so the gap is bottom-to-top distance.
      expect(beta.top - alpha.bottom, 8);

      final betaBottom = tester
          .getRect(
            find
                .ancestor(
                  of: find.text('beta'),
                  matching: find.byType(SizedBox),
                )
                .first,
          )
          .bottom;
      final headerTop = tester.getRect(find.text('AVAILABLE')).top;
      // 18px separator, then the header's own 2px top padding.
      expect(headerTop - betaBottom, 18 + 2);
    });
  });
}
