import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';
import 'package:grid_app/features/playground/logic/image_budget.dart';
import 'package:grid_app/features/playground/logic/message_media.dart';
import 'package:grid_app/features/playground/logic/playground_request.dart';

ChatMessage _withPictures(List<String> paths) => ChatMessage(
  role: ChatRole.user,
  text: 'look',
  media: [for (final p in paths) ChatMedia(path: p, kind: MediaKind.image)],
);

void main() {
  group('how much picture one request may carry', () {
    test('a full message of pictures at the cap still fits the relay body', () {
      final onTheWire = maxChatImages * base64Size(kMaxAttachmentBytes);
      expect(onTheWire, lessThan(kMaxRequestBytes));
    });

    test('base64 is measured, not guessed — it costs a third on top', () {
      expect(base64Size(3), 4);
      // Padded up to the next group of four, exactly as the encoder does.
      expect(base64Size(4), 8);
      expect(base64Size(1000000), 1333336);
    });
  });

  group('shrinking an oversized picture', () {
    test('the longest side decides the scale, so nothing is squashed', () {
      final size = targetImageSize(
        width: 4000,
        height: 2000,
        longestSide: 1000,
      );
      expect(size, (width: 1000, height: 500));
    });

    test('a tall picture is measured on its height', () {
      final size = targetImageSize(width: 900, height: 3600, longestSide: 900);
      expect(size, (width: 225, height: 900));
    });

    test(
      'a picture already that small is left alone rather than re-encoded',
      () {
        expect(
          targetImageSize(width: 800, height: 600, longestSide: 1568),
          isNull,
        );
      },
    );

    test('a picture with no pixels has no target — nothing to decode', () {
      expect(targetImageSize(width: 0, height: 0, longestSide: 512), isNull);
    });

    test(
      're-encoded bytes are renamed, so the wire says what they really are',
      () {
        expect(pngFilename('holiday.jpg'), 'holiday.png');
        expect(pngFilename('screenshot'), 'screenshot.png');
        // A dotfile has no extension to replace; the dot starts the name.
        expect(pngFilename('.hidden'), '.hidden.png');
      },
    );
  });

  group('the pictures of a conversation that fit one request', () {
    test('everything fits while the conversation is small', () {
      final history = [
        _withPictures(['a.png']),
        _withPictures(['b.png']),
      ];
      final budget = imagesWithinBudget(
        history,
        sizeOf: (_) => 1000,
        budgetBytes: 10000,
      );
      expect(budget.keep, {'a.png', 'b.png'});
      expect(budget.dropped, 0);
    });

    test('the newest pictures win — the question is about those', () {
      final history = [
        _withPictures(['oldest.png']),
        _withPictures(['older.png']),
        _withPictures(['newest.png']),
      ];
      final budget = imagesWithinBudget(
        history,
        sizeOf: (_) => 600,
        budgetBytes: 1200,
      );
      expect(budget.keep, {'newest.png', 'older.png'});
      expect(budget.dropped, 1);
    });

    test('a picture that is gone costs nothing, so a real one still fits', () {
      final history = [
        _withPictures(['deleted.png']),
        _withPictures(['here.png']),
      ];
      final budget = imagesWithinBudget(
        history,
        sizeOf: (path) => path == 'deleted.png' ? -1 : 1000,
        budgetBytes: 1000,
      );
      expect(budget.keep, {'here.png'});
      expect(budget.dropped, 0);
    });

    test('video is not counted — only pictures ride in the body', () {
      final history = [
        const ChatMessage(
          role: ChatRole.user,
          media: [ChatMedia(path: 'clip.mp4', kind: MediaKind.video)],
        ),
      ];
      final budget = imagesWithinBudget(
        history,
        sizeOf: (_) => 999999,
        budgetBytes: 10,
      );
      expect(budget.keep, isEmpty);
      expect(budget.dropped, 0);
    });
  });

  group('what the user is told about a picture that is too big', () {
    test('nothing at all when every picture went through', () {
      expect(oversizedAttachmentMessage(const []), isNull);
    });

    test('the one that failed is named, with something to do about it', () {
      final message = oversizedAttachmentMessage(['poster.png']);
      expect(message, contains('poster.png'));
      expect(message, contains('Crop it'));
    });

    test('several are counted rather than listed', () {
      final message = oversizedAttachmentMessage(['a.png', 'b.png', 'c.png']);
      expect(message, contains('“a.png” and 2 more are'));
    });
  });
}
