import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/playground/logic/message_media.dart';

MediaSegment _mediaAt(List<MessageSegment> segs, int i) =>
    segs[i] as MediaSegment;
String _textAt(List<MessageSegment> segs, int i) =>
    (segs[i] as TextSegment).text;

void main() {
  group('parseMessageSegments', () {
    test('plain text stays a single text segment', () {
      final segs = parseMessageSegments('hello **world**');
      expect(segs, hasLength(1));
      expect(_textAt(segs, 0), 'hello **world**');
    });

    test('markdown image becomes an image segment', () {
      final segs = parseMessageSegments('look ![cat](https://x.com/cat.png)');
      expect(segs, hasLength(2));
      expect(_textAt(segs, 0), 'look');
      expect(_mediaAt(segs, 1).kind, MediaKind.image);
      expect(_mediaAt(segs, 1).url, 'https://x.com/cat.png');
    });

    test('bare urls classify by extension', () {
      final segs = parseMessageSegments(
        'clip https://x.com/a.mp4 song https://x.com/b.mp3',
      );
      expect(_mediaAt(segs, 1).kind, MediaKind.video);
      expect(_mediaAt(segs, 3).kind, MediaKind.audio);
    });

    test('non-media links are kept inline as text, not media', () {
      final segs = parseMessageSegments('see https://example.com/page');
      expect(segs, hasLength(1));
      expect(_textAt(segs, 0), contains('https://example.com/page'));
    });

    test("markdown link's url is not mistaken for bare media", () {
      final segs = parseMessageSegments('[clip](https://x.com/a.mp4)');
      expect(segs, hasLength(1));
      expect(segs.first, isA<TextSegment>());
    });

    test('trailing sentence punctuation is trimmed from urls', () {
      final segs = parseMessageSegments('watch https://x.com/a.mp4.');
      expect(_mediaAt(segs, 1).url, 'https://x.com/a.mp4');
    });

    test('query strings do not break extension detection', () {
      final segs = parseMessageSegments('https://x.com/a.png?w=10&token=z');
      expect(_mediaAt(segs, 0).kind, MediaKind.image);
    });
  });
}
