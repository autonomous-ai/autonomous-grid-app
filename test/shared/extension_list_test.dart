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
}
