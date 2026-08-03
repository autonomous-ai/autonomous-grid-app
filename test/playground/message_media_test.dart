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

    // Linking bare URLs moved to the markdown layer: GitHub Flavored Markdown
    // autolinks them, including the cases hand-rolled code kept getting wrong
    // (inside a fence, inside a code span, a full stop after the URL). The
    // parser's job is only to decide what becomes *media*, so a plain web URL
    // now passes through untouched — see markdown_autolink_test.dart for the
    // rendered behaviour.
    test('a non-media url passes through for the markdown layer', () {
      final segs = parseMessageSegments('see https://example.com/page now');
      expect(segs, hasLength(1));
      expect(_textAt(segs, 0), 'see https://example.com/page now');
    });

    test('a url inside a fence is never lifted out as media', () {
      const src =
          "Here:\n```sh\nffmpeg -i /Users/me/clips/a.mp4 out.gif\n```\ndone";
      final segs = parseMessageSegments(src);
      // The path is part of the command, not a video to play.
      expect(segs.whereType<MediaSegment>(), isEmpty);
    });

    test('an already-markdown link is not double-wrapped', () {
      final segs = parseMessageSegments('[docs](https://example.com/page)');
      expect(_textAt(segs, 0), '[docs](https://example.com/page)');
    });

    test('a local path is left alone, not dressed as a web link', () {
      final segs = parseMessageSegments('saved to /Users/me/notes.txt');
      expect(_textAt(segs, 0), 'saved to /Users/me/notes.txt');
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

    test('a bare local image path becomes an image segment', () {
      // What the agent writes after generating an image.
      final segs = parseMessageSegments(
        'File: /Users/me/Downloads/output_image_001.png',
      );
      expect(_mediaAt(segs, 1).kind, MediaKind.image);
      expect(_mediaAt(segs, 1).url, '/Users/me/Downloads/output_image_001.png');
    });

    test('a local video path becomes a video segment', () {
      final segs = parseMessageSegments('/Users/me/clips/a.mp4');
      expect(_mediaAt(segs, 0).kind, MediaKind.video);
    });

    test('a non-media local path is left as text', () {
      final segs = parseMessageSegments('saved to /Users/me/notes.txt');
      expect(segs, hasLength(1));
      expect(segs.first, isA<TextSegment>());
    });

    test('a markdown link to a local media file is lifted to media', () {
      final segs = parseMessageSegments('[open](/Users/me/a.png)');
      expect(segs, hasLength(1));
      expect(_mediaAt(segs, 0).kind, MediaKind.image);
    });

    test('a local media path wrapped in inline-code backticks still lifts', () {
      // The agent often reports files as `**File:** ` + a backtick-wrapped path.
      final segs = parseMessageSegments(
        '**File:** `/Users/me/Downloads/grid_video_001.mp4`  ',
      );
      final media = segs.whereType<MediaSegment>().single;
      expect(media.kind, MediaKind.video);
      expect(media.url, '/Users/me/Downloads/grid_video_001.mp4');
    });

    test('the image skill\'s #media: marker is rendered inline', () {
      // A skill that saves an image replies with this exact shape.
      final segs = parseMessageSegments(
        '[File: /Users/me/Downloads/img_001.png](#media:/Users/me/Downloads/img_001.png)',
      );
      expect(segs, hasLength(1));
      expect(_mediaAt(segs, 0).kind, MediaKind.image);
      expect(_mediaAt(segs, 0).url, '/Users/me/Downloads/img_001.png');
    });
  });

  group('local media helpers', () {
    test('classifies bare paths and file:// as local, http as not', () {
      expect(isLocalMediaUrl('/Users/me/a.png'), isTrue);
      expect(isLocalMediaUrl('file:///Users/me/a.png'), isTrue);
      expect(isLocalMediaUrl('https://x.com/a.png'), isFalse);
    });

    test('decodes a file:// url to a plain path', () {
      expect(localMediaPath('file:///Users/me/a%20b.png'), '/Users/me/a b.png');
      expect(localMediaPath('/Users/me/a.png'), '/Users/me/a.png');
    });
  });
}
