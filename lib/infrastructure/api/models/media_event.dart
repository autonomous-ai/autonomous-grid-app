import 'dart:convert';

/// SSE events from the relay media endpoints — `media/image/generate`,
/// `media/image/edit`, `media/video/i2v` (cli.py:958). See
/// CLI_Integration_Contract §4.2.
sealed class MediaEvent {
  const MediaEvent();

  /// Parse the payload after `data: `. Returns null for `[DONE]` or unknown
  /// event shapes.
  static MediaEvent? fromSseData(String data) {
    final trimmed = data.trim();
    if (trimmed.isEmpty || trimmed == '[DONE]') return null;
    final Object? decoded = jsonDecode(trimmed);
    if (decoded is! Map<String, dynamic>) return null;

    if (decoded['error'] != null) {
      return MediaError(decoded['error'].toString());
    }
    switch (decoded['type']) {
      case 'progress':
        return MediaProgress(
          progress: (decoded['progress'] as num?)?.toDouble() ?? 0,
          status: (decoded['status'] ?? 'running') as String,
        );
      case 'result':
        final files = decoded['output_files'];
        return MediaResult(
          files is List
              ? files
                  .whereType<Map>()
                  .map((f) => MediaFile(
                        filename: f['filename'] as String,
                        contentBase64: f['content_base64'] as String,
                      ))
                  .toList()
              : const [],
        );
      default:
        return null;
    }
  }
}

class MediaProgress extends MediaEvent {
  const MediaProgress({required this.progress, required this.status});
  final double progress;
  final String status;
}

class MediaResult extends MediaEvent {
  const MediaResult(this.files);
  final List<MediaFile> files;
}

class MediaError extends MediaEvent {
  const MediaError(this.message);
  final String message;
}

/// A returned media file. Decode [contentBase64] and write under
/// `~/.grid/outputs` (cli.py:1007).
class MediaFile {
  const MediaFile({required this.filename, required this.contentBase64});
  final String filename;
  final String contentBase64;

  List<int> decodeBytes() => base64.decode(contentBase64);
}
