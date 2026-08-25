import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/playground/logic/image_shrink.dart';
import 'package:grid_app/features/playground/logic/playground_request.dart';

/// A real encoded PNG of [width]×[height], drawn rather than checked in — the
/// point of these tests is what the codec does with a picture, and a fixture
/// file big enough to matter has no business in the repo.
Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final paint = ui.Paint();
  // Noise, not flat colour: a single-colour picture compresses to nothing and
  // would never exercise a byte budget.
  for (var x = 0; x < width; x += 7) {
    paint.color = ui.Color(0xFF000000 | (x * 2654435761) & 0xFFFFFF);
    canvas.drawRect(
      ui.Rect.fromLTWH(x.toDouble(), 0, 7, height.toDouble()),
      paint,
    );
  }
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('fitting a picture into what a request may carry', () {
    test(
      'a picture already inside the budget is passed through untouched',
      () async {
        final bytes = await _png(200, 150);
        final image = MediaAttachment(filename: 'small.png', bytes: bytes);
        final fitted = await fitImageToBudget(image, budgetBytes: 1000000);
        expect(fitted, same(image));
      },
    );

    test('an oversized picture comes back smaller than its budget', () async {
      final bytes = await _png(4000, 3000);
      final fitted = await fitImageToBudget(
        MediaAttachment(filename: 'screenshot.png', bytes: bytes),
        budgetBytes: 20000,
      );
      expect(fitted, isNotNull);
      expect(fitted!.bytes.length, lessThanOrEqualTo(20000));
    });

    test(
      'a shrunk picture is renamed, because the bytes are now PNG',
      () async {
        final bytes = await _png(4000, 3000);
        final fitted = await fitImageToBudget(
          MediaAttachment(filename: 'holiday.jpg', bytes: bytes),
          budgetBytes: 20000,
        );
        // The wire's MIME type comes from the filename: PNG bytes under a .jpg
        // name reach the model labelled as something they are not.
        expect(fitted?.filename, 'holiday.png');
      },
    );

    test('bytes that are not a picture at all are refused, not sent', () async {
      final fitted = await fitImageToBudget(
        MediaAttachment(filename: 'broken.png', bytes: Uint8List(300000)),
        budgetBytes: 1000,
      );
      expect(fitted, isNull);
    });
  });
}
