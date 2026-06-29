import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../logic/message_media.dart';
import 'media/inline_audio.dart';
import 'media/inline_image.dart';
import 'media/inline_video.dart';
import 'media/media_chrome.dart';

/// Renders a chat message body: markdown text segments via [GptMarkdown], with
/// any inline images / videos / audio lifted out into their own players. See
/// [parseMessageSegments] for how the message is split.
class MessageContent extends StatelessWidget {
  const MessageContent({
    super.key,
    required this.text,
    required this.color,
  });

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final segments = parseMessageSegments(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < segments.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _segment(context, segments[i]),
        ],
      ],
    );
  }

  Widget _segment(BuildContext context, MessageSegment segment) {
    return switch (segment) {
      TextSegment(:final text) => SelectionArea(
          child: GptMarkdown(
            text,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: color),
            onLinkTap: (url, _) => openExternalUrl(url),
          ),
        ),
      MediaSegment(:final url, kind: MediaKind.image) => InlineImage(url: url),
      MediaSegment(:final url, kind: MediaKind.video) => InlineVideo(url: url),
      MediaSegment(:final url, kind: MediaKind.audio) => InlineAudio(url: url),
    };
  }
}
