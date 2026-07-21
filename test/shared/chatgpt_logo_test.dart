import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/shared/widgets/chatgpt_logo.dart';

/// The mark is vector paths converted from the published 24×24 SVG, arcs and
/// all — and SVG's sweep-flag is the inverse of Flutter's `clockwise`, which
/// doesn't throw when you get it wrong, it just bulges every curve outwards.
/// So the geometry is checked here rather than left to be spotted on screen.
void main() {
  group('the OpenAI mark', () {
    test('fills its 24x24 box without any curve escaping it', () {
      final bounds = openAiMarkPath().getBounds();

      expect(bounds.left, closeTo(1, 0.5));
      expect(bounds.top, closeTo(2, 0.5));
      expect(bounds.right, closeTo(23, 0.5));
      expect(bounds.bottom, closeTo(24, 0.5));
    });

    test('is solid where its four lobes are, so it renders as a glyph rather '
        'than an outline that lost its fill', () {
      final path = openAiMarkPath();

      expect(path.contains(const Offset(12, 4)), isTrue);
      expect(path.contains(const Offset(12, 20)), isTrue);
      expect(path.contains(const Offset(4, 12)), isTrue);
      expect(path.contains(const Offset(20, 12)), isTrue);
    });

    test('keeps the hole at its centre — the knot is not a filled blob', () {
      expect(openAiMarkPath().contains(const Offset(12, 12)), isFalse);
    });

    test(
      'leaves the corners empty, so it reads as a mark and not a square',
      () {
        final path = openAiMarkPath();

        expect(path.contains(const Offset(1, 1)), isFalse);
        expect(path.contains(const Offset(23.5, 23.5)), isFalse);
      },
    );
  });
}
