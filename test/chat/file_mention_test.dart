import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/file_mention.dart';

void main() {
  group('activeMention — when the @ file menu should open', () {
    test('an @ token at the cursor gives its query', () {
      final mention = activeMention('summarize @rep', 14);
      expect(mention, isNotNull);
      expect(mention!.start, 10);
      expect(mention.query, 'rep');
    });

    test('a bare @ opens the menu with an empty query', () {
      expect(activeMention('@', 1)!.query, '');
    });

    test('an @ mid-word (an email) is not a mention', () {
      expect(activeMention('mail a@b.com', 12), isNull);
    });

    test('a space after the @ token closes the menu', () {
      // Cursor past the space: "look @a " — no longer a single token.
      expect(activeMention('look @a b', 9), isNull);
    });

    test('only the @ before the cursor counts, not one typed later', () {
      // Cursor sits right after "@a"; the trailing text is ignored.
      expect(activeMention('see @a and @b', 6)!.query, 'a');
    });
  });

  group('applyMention — dropping the picked file in', () {
    test('replaces the @query with the name and a trailing space', () {
      final result = applyMention(
        'see @no',
        7,
        activeMention('see @no', 7)!,
        'notes.md',
      );
      expect(result.text, 'see notes.md ');
      expect(result.cursor, 'see notes.md '.length);
    });

    test('keeps whatever followed the cursor', () {
      final result = applyMention(
        'read @no please',
        8,
        activeMention('read @no please', 8)!,
        'notes.md',
      );
      expect(result.text, 'read notes.md  please');
    });
  });
}
