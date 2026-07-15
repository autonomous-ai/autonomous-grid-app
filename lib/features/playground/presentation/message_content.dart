import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../logic/chat_message.dart';
import '../logic/message_media.dart';
import 'media/inline_audio.dart';
import 'media/inline_image.dart';
import 'media/inline_video.dart';
import 'media/local_media_view.dart';
import 'media/media_chrome.dart';

/// Renders a chat message body: markdown text segments via [GptMarkdown], any
/// inline images / videos / audio linked in the text lifted out into their own
/// players, then any generated [media] files (saved locally) below. See
/// [parseMessageSegments] for how the text is split.
class MessageContent extends StatelessWidget {
  const MessageContent({
    super.key,
    required this.text,
    required this.color,
    this.media = const [],
  });

  final String text;
  final Color color;
  final List<ChatMedia> media;

  @override
  Widget build(BuildContext context) {
    final segments = text.isEmpty
        ? const <MessageSegment>[]
        : parseMessageSegments(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < segments.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _segment(context, segments[i]),
        ],
        for (var i = 0; i < media.length; i++) ...[
          if (i > 0 || segments.isNotEmpty) const SizedBox(height: 8),
          LocalMediaView(media: media[i]),
        ],
      ],
    );
  }

  Widget _segment(BuildContext context, MessageSegment segment) {
    return switch (segment) {
      TextSegment(:final text) => SelectionArea(
        child: GptMarkdown(
          text,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: color),
          onLinkTap: (url, _) => openExternalUrl(url),
        ),
      ),
      // A file the agent wrote to disk (a generated image/video): render it from
      // the file, the same way saved outputs are shown, rather than as a link
      // the OS can't open.
      MediaSegment(:final url, :final kind) when isLocalMediaUrl(url) =>
        LocalMediaView(
          media: ChatMedia(path: localMediaPath(url), kind: kind),
        ),
      MediaSegment(:final url, kind: MediaKind.image) => InlineImage(url: url),
      MediaSegment(:final url, kind: MediaKind.video) => InlineVideo(
        source: url,
      ),
      MediaSegment(:final url, kind: MediaKind.audio) => InlineAudio(url: url),
    };
  }
}
