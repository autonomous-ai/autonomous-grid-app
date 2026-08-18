import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../shared/external_launch.dart';
import '../../logic/message_media.dart';
import 'media_chrome.dart';

/// An image referenced from a chat message — capped in height and clipped to the
/// app's media radius.
///
/// Two sources, decided by the URL. A `data:image/…;base64,…` URI carries the
/// image inline (an agent embedding a screenshot in its reply), so its bytes are
/// decoded once and drawn from memory — the network loader can't fetch a `data:`
/// URL and used to fail every one of them. Anything else is fetched and cached
/// over the network, and tapping it opens the full size externally.
class InlineImage extends StatefulWidget {
  const InlineImage({super.key, required this.url});
  final String url;

  @override
  State<InlineImage> createState() => _InlineImageState();
}

class _InlineImageState extends State<InlineImage> {
  /// Decoded once here rather than in `build` — a base64 screenshot runs to
  /// hundreds of KB, and decoding it on every rebuild would re-upload it to the
  /// GPU each time. Null for a network URL, which loads the usual way.
  Uint8List? _inlineBytes;

  @override
  void initState() {
    super.initState();
    _inlineBytes = decodeImageDataUri(widget.url);
  }

  @override
  void didUpdateWidget(InlineImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _inlineBytes = decodeImageDataUri(widget.url);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _inlineBytes;
    final error = MediaErrorBox(
      url: widget.url,
      icon: Icons.broken_image_outlined,
      label: 'Image failed to load',
    );
    final image = bytes == null
        ? CachedNetworkImage(
            imageUrl: widget.url,
            fit: BoxFit.contain,
            alignment: Alignment.centerLeft,
            placeholder: (_, _) => const MediaLoadingBox(),
            errorWidget: (_, _, _) => error,
          )
        : Image.memory(
            bytes,
            fit: BoxFit.contain,
            alignment: Alignment.centerLeft,
            errorBuilder: (_, _, _) => error,
          );
    final framed = ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: kMediaMaxHeight),
      child: ClipRRect(borderRadius: kMediaRadius, child: image),
    );
    // A data URI is the whole image already — there is no address to open.
    if (bytes != null) return framed;
    return GestureDetector(
      onTap: () => openExternalUrl(widget.url),
      child: framed,
    );
  }
}
