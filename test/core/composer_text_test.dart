import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/core/composer_text.dart';

void main() {
  group('pasting into the composer', () {
    test('lands at the cursor, where the field would have put it', () {
      final result = insertIntoField('Hi !', start: 3, end: 3, insert: 'there');

      expect(result.text, 'Hi there!');
      expect(result.cursor, 8);
    });

    test(
      'replaces the selection, so paste-over works like everywhere else',
      () {
        final result = insertIntoField(
          'Hi there!',
          start: 3,
          end: 8,
          insert: 'friend',
        );

        expect(result.text, 'Hi friend!');
      },
    );

    test('goes on the end when the box was never focused — the keystroke '
        'must not throw away what was pasted', () {
      final result = insertIntoField('Draft', start: -1, end: -1, insert: '!');

      expect(result.text, 'Draft!');
      expect(result.cursor, 6);
    });
  });

  group('paths dropped into a message', () {
    test('are separated and leave room for the sentence that follows', () {
      expect(pathsForMessage(['/a/b.txt', '/c/d.txt']), '/a/b.txt /c/d.txt ');
    });

    test('nothing to insert stays nothing, not a stray space', () {
      expect(pathsForMessage(['', '   ']), '');
    });
  });
}
