import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../shared/external_launch.dart';
import 'media_chrome.dart';

/// A network image referenced from a chat message — cached, capped in height,
/// tappable to open full-size externally.
class InlineImage extends StatelessWidget {
  const InlineImage({super.key, required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => openExternalUrl(url),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: kMediaMaxHeight),
        child: ClipRRect(
          borderRadius: kMediaRadius,
          child: CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.contain,
            alignment: Alignment.centerLeft,
            placeholder: (_, _) => const MediaLoadingBox(),
            errorWidget: (_, _, _) => MediaErrorBox(
              url: url,
              icon: Icons.broken_image_outlined,
              label: 'Image failed to load',
            ),
          ),
        ),
      ),
    );
  }
}
