import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/playground/presentation/attachment_bar.dart';

void main() {
  group('isImageFilename', () {
    test('accepts the image types the picker offers, case-insensitively', () {
      const names = [
        'photo.png',
        'shot.JPG',
        'a.jpeg',
        'b.WEBP',
        'c.gif',
        'd.bmp',
        // The exact shape a macOS screenshot drop delivers — a temp path.
        '/var/folders/8q/T/TemporaryItems/NSIRD_x/Screenshot 2026-07-29.png',
      ];
      for (final name in names) {
        expect(isImageFilename(name), isTrue, reason: name);
      }
    });

    test('rejects non-images and names with no extension', () {
      const names = ['notes.txt', 'main.dart', 'archive.zip', 'README', ''];
      for (final name in names) {
        expect(isImageFilename(name), isFalse, reason: name);
      }
    });

    test('keys off the last dot, so a double extension is judged by its tail', () {
      // A dotted folder with an image at the end is still an image...
      expect(isImageFilename('my.photos/v2.final.PNG'), isTrue);
      // ...but a real image renamed to a backup is not one to attach.
      expect(isImageFilename('image.png.bak'), isFalse);
    });
  });
}
