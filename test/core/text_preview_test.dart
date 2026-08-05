import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/core/text_preview.dart';

void main() {
  group('firstLinePreview', () {
    test('quotes the answer rather than the blank lines above it', () {
      expect(
        firstLinePreview('\n\n  Three PRs need review today.\nThen the rest.'),
        'Three PRs need review today.',
      );
    });

    test('a markdown heading arrives as prose, not as hashes', () {
      expect(firstLinePreview('## Your morning brief'), 'Your morning brief');
    });

    test('a bullet loses its dash so the banner reads as a sentence', () {
      expect(
        firstLinePreview('- Deploy failed on staging'),
        'Deploy failed on staging',
      );
    });

    test('a quoted line loses its marker too', () {
      expect(
        firstLinePreview('> Nothing changed overnight'),
        'Nothing changed overnight',
      );
    });

    test('an over-long line is cut at a word, never mid-word', () {
      final line =
          'The nightly build failed because the signing certificate '
          'expired at midnight and nobody renewed it before the release ran.';
      final preview = firstLinePreview(line, maxChars: 40);
      expect(preview.endsWith('…'), isTrue);
      expect(preview.length, lessThanOrEqualTo(41));
      // Cut on a boundary: what's left is whole words from the original.
      expect(line.startsWith(preview.substring(0, preview.length - 1)), isTrue);
      expect(preview.substring(0, preview.length - 1).endsWith(' '), isFalse);
    });

    test('an unbreakable line is cut where it is rather than shown empty', () {
      final preview = firstLinePreview('a' * 200, maxChars: 20);
      expect(preview, '${'a' * 20}…');
    });

    test(
      'nothing to say comes back empty, so the caller can say so itself',
      () {
        expect(firstLinePreview(''), isEmpty);
        expect(firstLinePreview('\n\n   \n'), isEmpty);
        expect(firstLinePreview('###'), isEmpty);
      },
    );
  });
}
