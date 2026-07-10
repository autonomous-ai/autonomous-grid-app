import 'dart:io';

import 'package:flutter/material.dart';

import '../../logic/chat_message.dart';
import '../../logic/message_media.dart';
import 'inline_video.dart';
import 'media_chrome.dart';

/// Renders a generated media file from disk (`~/.grid/outputs`): an image via
/// [Image.file], a video via the inline player, both tappable to open in the
/// system viewer. Anything else falls back to an "open file" row.
class LocalMediaView extends StatelessWidget {
  const LocalMediaView({super.key, required this.media});
  final ChatMedia media;

  @override
  Widget build(BuildContext context) {
    final href = Uri.file(media.path).toString();
    return switch (media.kind) {
      MediaKind.image => _LocalImage(path: media.path, href: href),
      MediaKind.video => InlineVideo(source: media.path, openHref: href),
      MediaKind.audio => MediaErrorBox(
          url: href,
          icon: Icons.audiotrack_outlined,
          label: media.path.split('/').last,
        ),
    };
  }
}

/// A generated image from a local file — capped in height, tap to open full-size.
class _LocalImage extends StatelessWidget {
  const _LocalImage({required this.path, required this.href});
  final String path;
  final String href;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => openExternalUrl(href),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: kMediaMaxHeight),
        child: ClipRRect(
          borderRadius: kMediaRadius,
          child: Image.file(
            File(path),
            fit: BoxFit.contain,
            alignment: Alignment.centerLeft,
            errorBuilder: (_, _, _) => MediaErrorBox(
              url: href,
              icon: Icons.broken_image_outlined,
              label: 'Image failed to load',
            ),
          ),
        ),
      ),
    );
  }
}
