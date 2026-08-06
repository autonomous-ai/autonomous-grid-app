import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Text out of the file formats only the operating system can read.
///
/// PDF is the one that matters: it is the most-attached office file there is,
/// and it is not zipped XML — there is no honest way to read it in Dart. macOS
/// already ships a reader (PDFKit), so the app asks it rather than shipping a
/// parser that would return plausible nonsense for half the files people have.
class NativeDocuments {
  const NativeDocuments._();

  static const MethodChannel _channel = MethodChannel('grid/documents');

  /// Whether this platform has a reader behind [pdfText] at all. Windows and
  /// Linux don't yet — a PDF there is attached by path, and the composer says
  /// so instead of silently sending an empty document.
  static bool get readsPdf => Platform.isMacOS;

  /// The text inside the PDF at [path], or null when there is none to be had —
  /// a scan with no text layer, an encrypted file, a platform with no reader, or
  /// a `flutter test` run with nothing listening on the channel.
  static Future<String?> pdfText(String path) async {
    if (!readsPdf) return null;
    try {
      final text = await _channel.invokeMethod<String>('pdfText', {
        'path': path,
      });
      final trimmed = text?.trim() ?? '';
      return trimmed.isEmpty ? null : trimmed;
    } on Object catch (error) {
      debugPrint('NativeDocuments: could not read $path — $error');
      return null;
    }
  }
}
