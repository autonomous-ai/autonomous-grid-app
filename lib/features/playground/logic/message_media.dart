/// Splits a chat message into renderable segments: markdown text and inline
/// media (image / video / audio). Media is discovered from the message text
/// itself — markdown image syntax (`![alt](url)`) and bare URLs whose extension
/// names a media type — since the transcript carries no structured attachments.
library;

enum MediaKind { image, video, audio }

sealed class MessageSegment {
  const MessageSegment();
}

class TextSegment extends MessageSegment {
  const TextSegment(this.text);
  final String text;
}

class MediaSegment extends MessageSegment {
  const MediaSegment({required this.url, required this.kind});
  final String url;
  final MediaKind kind;
}

const _imageExt = {
  'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg', 'avif', 'apng', 'heic',
};
const _videoExt = {'mp4', 'mov', 'webm', 'mkv', 'm4v', 'avi', 'ogv', '3gp'};
const _audioExt = {
  'mp3', 'wav', 'm4a', 'aac', 'ogg', 'oga', 'flac', 'opus', 'weba',
};

/// Markdown image, then markdown link, then bare URL — in that priority order so
/// a link's own URL is never mistaken for a bare media URL.
final _mediaPattern = RegExp(
  r'!\[[^\]]*\]\(\s*([^)\s]+)[^)]*\)' // 1: markdown image url
  r'|'
  r'\[[^\]]*\]\(\s*[^)\s]+[^)]*\)' // markdown link → kept as text
  r'|'
  r'(https?://[^\s<>()\[\]"]+)', // 2: bare url
);

/// Parse [text] into ordered segments. Always returns at least one segment.
List<MessageSegment> parseMessageSegments(String text) {
  final segments = <MessageSegment>[];
  final buffer = StringBuffer();

  void flushText() {
    final pending = buffer.toString().trim();
    if (pending.isNotEmpty) segments.add(TextSegment(pending));
    buffer.clear();
  }

  void addMedia(String url, MediaKind kind) {
    flushText();
    segments.add(MediaSegment(url: _trimTrailingPunctuation(url), kind: kind));
  }

  var last = 0;
  for (final match in _mediaPattern.allMatches(text)) {
    buffer.write(text.substring(last, match.start));
    last = match.end;

    final imageUrl = match.group(1);
    if (imageUrl != null) {
      addMedia(imageUrl, mediaKindForPath(imageUrl) ?? MediaKind.image);
      continue;
    }

    final bareUrl = match.group(2);
    final kind = bareUrl == null ? null : mediaKindForPath(bareUrl);
    if (bareUrl != null && kind != null) {
      addMedia(bareUrl, kind);
      continue;
    }

    // Markdown link, or a non-media bare URL: keep verbatim for markdown.
    buffer.write(match.group(0));
  }
  buffer.write(text.substring(last));
  flushText();

  if (segments.isEmpty) segments.add(TextSegment(text.trim()));
  return segments;
}

/// The [MediaKind] a URL or filename names by its extension, or null if the
/// extension isn't a known media type. Shared by the message parser and the
/// saved-output renderer so both classify files the same way.
MediaKind? mediaKindForPath(String pathOrUrl) {
  final ext = _extensionOf(_trimTrailingPunctuation(pathOrUrl));
  if (ext == null) return null;
  if (_imageExt.contains(ext)) return MediaKind.image;
  if (_videoExt.contains(ext)) return MediaKind.video;
  if (_audioExt.contains(ext)) return MediaKind.audio;
  return null;
}

String? _extensionOf(String url) {
  final clean = url.split('#').first.split('?').first;
  final slash = clean.lastIndexOf('/');
  final name = slash >= 0 ? clean.substring(slash + 1) : clean;
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return null;
  return name.substring(dot + 1).toLowerCase();
}

/// Trailing sentence punctuation clings to bare URLs ("see foo.mp4.") — drop it
/// so the extension and the fetched URL stay clean.
String _trimTrailingPunctuation(String url) {
  var end = url.length;
  while (end > 0 && '.,;:!?)'.contains(url[end - 1])) {
    end--;
  }
  return url.substring(0, end);
}
